// The flow of ninja v1.13.2 src/ninja.cc (Apache-2.0, see NOTICE). The
// host runs commands asynchronously, so each step that runs a build takes
// a continuation instead of returning.

///|
/// One attempt at loading and building (ninja's `NinjaMain`; a new one
/// starts after the manifest rebuilds itself).
priv struct Ninja {
  host : Host
  options : Options
  config : @moonja.BuildConfig
  status : @moonja.StatusPrinter
  state : @moonja.State
  build_log : @moonja.BuildLog
  deps_log : @moonja.DepsLog
  mut build_dir : String
  start_time_millis : Int64
  /// What Ctrl-C does while a build runs.
  interrupt : Ref[(() -> Unit)?]
}

///|
/// For results of the steps that cannot raise.
fn Host::fatal_no_raise(self : Host, message : String) -> Unit {
  self.terminal.write_err("ninja: fatal: \{message}\n")
  (self.exit)(1)
}

///|
/// Runs ninja with the command-line arguments (without the program name).
pub fn run(host : Host, args : Array[String]) -> Unit {
  host.run_guarded(fn() raise Quit { real_main(host, args) })
}

///|
fn real_main(host : Host, args : Array[String]) -> Unit raise Quit {
  let options = match read_flags(host, args) {
    Ok(options) => options
    Err(code) => raise Quit(code)
  }
  let format = (host.getenv)("NINJA_STATUS").unwrap_or("[%f/%t] ")
  let status = @moonja.StatusPrinter::new(
    options.config,
    host.terminal,
    format~,
  )
  let interrupt : Ref[(() -> Unit)?] = Ref(None)
  (host.on_interrupt)(fn() {
    match interrupt.val {
      Some(handler) => handler()
      None => (host.exit)(130)
    }
  })
  if options.working_dir is Some(dir) {
    // The funny quotes let Emacs follow the directory change. Tools stay
    // quiet so their output can be piped.
    if options.tool is None && !(options.config.verbosity is NoStatusUpdate) {
      @moonja.Status::info(status, "Entering directory `\{dir}'")
    }
    if (host.chdir)(dir) is Some(error) {
      host.fatal("chdir to '\{dir}' - \{error}")
    }
  }
  if options.tool is Some(tool) && tool.when is AfterFlags {
    let ninja = Ninja::new(host, options, status, interrupt)
    raise Quit(ninja.run_tool(tool))
  }
  run_cycle(host, options, status, interrupt, 1)
}

///|
/// Rebuilding the manifest more often than this means a loop.
let cycle_limit : Int32 = 100

///|
fn run_cycle(
  host : Host,
  options : Options,
  status : @moonja.StatusPrinter,
  interrupt : Ref[(() -> Unit)?],
  cycle : Int32,
) -> Unit raise Quit {
  if cycle > cycle_limit {
    @moonja.Status::error(
      status,
      "manifest '\{options.input_file}' still dirty after \{cycle_limit} tries, perhaps system time is not set",
    )
    raise Quit(1)
  }
  let ninja = Ninja::new(host, options, status, interrupt)
  ninja.load_manifest()
  if options.tool is Some(tool) && tool.when is AfterLoad {
    raise Quit(ninja.run_tool(tool))
  }
  if !ninja.ensure_build_dir_exists() {
    raise Quit(1)
  }
  if !ninja.open_build_log(false) || !ninja.open_deps_log(false) {
    raise Quit(1)
  }
  if options.tool is Some(tool) && tool.when is AfterLogs {
    raise Quit(ninja.run_tool(tool))
  }
  // Rebuild the manifest before anything else.
  ninja.rebuild_manifest(fn(rebuilt, error) raise Quit {
    if rebuilt {
      // A dry run would "rebuild" the manifest forever.
      if options.config.dry_run {
        raise Quit(0)
      }
      ninja.close_logs()
      run_cycle(host, options, status, interrupt, cycle + 1)
    } else if error != "" {
      @moonja.Status::error(
        status,
        "rebuilding '\{options.input_file}': \{error}",
      )
      raise Quit(1)
    } else {
      ninja.parse_previous_elapsed_times()
      ninja.run_build(fn(code) raise Quit {
        if @moonja.metrics_enabled() {
          host.print(ninja.state.dump_metrics())
        }
        raise Quit(code)
      })
    }
  })
}

///|
fn Ninja::new(
  host : Host,
  options : Options,
  status : @moonja.StatusPrinter,
  interrupt : Ref[(() -> Unit)?],
) -> Ninja {
  {
    host,
    options,
    config: options.config,
    status,
    state: @moonja.State::new(platform=host.platform),
    build_log: @moonja.BuildLog::new(),
    deps_log: @moonja.DepsLog::new(),
    build_dir: "",
    start_time_millis: (host.now_millis)(),
    interrupt,
  }
}

///|
fn Ninja::error(self : Ninja, message : String) -> Unit {
  @moonja.Status::error(self.status, message)
}

///|
fn Ninja::warning(self : Ninja, message : String) -> Unit {
  @moonja.Status::warning(self.status, message)
}

///|
fn Ninja::load_manifest(self : Ninja) -> Unit raise Quit {
  let parser = @moonja.ManifestParser::new(self.state, reader=self.host.files, options={
    phony_cycle_action: if self.options.phony_cycle_should_err {
      Error
    } else {
      Warn
    },
  })
  let failure = try {
    parser.load(self.options.input_file)
    None
  } catch {
    error => Some(error)
  }
  for warning in parser.warnings() {
    self.warning(warning)
  }
  match failure {
    None => ()
    // ninja calls Fatal() for an incompatible ninja_required_version.
    Some(Fatal(_) as error) => self.host.fatal(error.message())
    Some(error) => {
      self.error(error.message())
      raise Quit(1)
    }
  }
}

///|
fn Ninja::ensure_build_dir_exists(self : Ninja) -> Bool {
  self.build_dir = self.state.bindings().lookup("builddir")
  if self.build_dir != "" && !self.config.dry_run {
    let ok = @moonja.make_dirs(
      self.host.disk,
      self.build_dir + "/.",
      platform=self.host.platform,
    ) catch {
      error => {
        self.error(
          "creating build directory \{self.build_dir}: \{error.message()}",
        )
        return false
      }
    }
    if !ok {
      self.error("creating build directory \{self.build_dir}")
      return false
    }
  }
  true
}

///|
fn Ninja::log_path(self : Ninja, name : String) -> String {
  if self.build_dir == "" {
    name
  } else {
    self.build_dir + "/" + name
  }
}

///|
/// Whether a build log entry can be dropped: nothing builds it and it is
/// gone from disk (ninja's `NinjaMain::IsPathDead`).
fn Ninja::is_path_dead(self : Ninja, path : String) -> Bool {
  if self.state.lookup_node(path) is Some(node) && node.in_edge() is Some(_) {
    return false
  }
  // Keep entries for files that still exist, for generators.
  let mtime = self.host.disk.stat(path) catch {
    error => {
      self.error(error.message())
      -1
    }
  }
  mtime == 0
}

///|
fn Ninja::open_build_log(self : Ninja, recompact_only : Bool) -> Bool {
  let path = self.log_path(".ninja_log")
  let (status, warning) = self.build_log.load(self.host.disk, path) catch {
    error => {
      self.error("loading build log \{path}: \{error.message()}")
      return false
    }
  }
  if warning != "" {
    self.warning(warning)
  }
  let is_path_dead = fn(p) { self.is_path_dead(p) }
  if recompact_only {
    if status is @moonja.LoadStatus::NotFound {
      return true
    }
    self.build_log.recompact(self.host.disk, path, is_path_dead) catch {
      error => {
        self.error("failed recompaction: \{error.message()}")
        return false
      }
    }
    return true
  }
  if !self.config.dry_run {
    self.build_log.open_for_write(self.host.disk, path, is_path_dead) catch {
      error => {
        self.error("opening build log: \{error.message()}")
        return false
      }
    }
  }
  true
}

///|
fn Ninja::open_deps_log(self : Ninja, recompact_only : Bool) -> Bool {
  let path = self.log_path(".ninja_deps")
  let (status, warning) = self.deps_log.load(self.host.disk, path, self.state) catch {
    error => {
      self.error("loading deps log \{path}: \{error.message()}")
      return false
    }
  }
  if warning != "" {
    self.warning(warning)
  }
  if recompact_only {
    if status is @moonja.LoadStatus::NotFound {
      return true
    }
    self.deps_log.recompact(self.host.disk, path) catch {
      error => {
        self.error("failed recompaction: \{error.message()}")
        return false
      }
    }
    return true
  }
  if !self.config.dry_run {
    self.deps_log.open_for_write(self.host.disk, path) catch {
      error => {
        self.error("opening deps log: \{error.message()}")
        return false
      }
    }
  }
  true
}

///|
/// Flushes the logs, as ninja's destructors do between manifest rebuilds.
fn Ninja::close_logs(self : Ninja) -> Unit {
  if self.config.dry_run {
    return
  }
  self.build_log.close(self.host.disk) catch {
    error => self.error(error.message())
  }
  self.deps_log.close(self.host.disk) catch {
    error => self.error(error.message())
  }
}

///|
fn Ninja::new_builder(self : Ninja) -> @moonja.Builder {
  let builder = @moonja.Builder::new(
    self.state,
    self.config,
    self.host.disk,
    status=self.status,
    build_log=self.build_log,
    deps_log=self.deps_log,
    start_time_millis=self.start_time_millis,
    clock=self.host.now_millis,
    cwd=(self.host.cwd)(),
  )
  self.status.set_explanations(builder.explanations())
  builder
}

///|
/// Runs the build, then calls `done` with its status and error message.
fn Ninja::drive(
  self : Ninja,
  builder : @moonja.Builder,
  done : (@moonja.ExitStatus, String) -> Unit raise Quit,
) -> Unit raise Quit {
  // ninja's Builder always cleans up when destroyed, after a successful
  // build too: that is what removes .ninja_lock.
  if self.config.dry_run {
    let runner = DryRunRunner::{ finished: [], next: 0, }
    let (status, message) = builder.build(runner)
    builder.cleanup(runner)
    done(status, message)
    return
  }
  let runner = ProcessRunner::new(self.host, self.config)
  let finish = fn(progress : @moonja.BuildProgress) raise Quit {
    match progress {
      Waiting => ()
      Finished(status, message) => {
        self.interrupt.val = None
        builder.cleanup(runner)
        done(status, message)
      }
    }
  }
  runner.on_result = fn(result) {
    self.host.run_guarded(fn() raise Quit {
      finish(builder.command_finished(runner, Some(result)))
    })
  }
  self.interrupt.val = Some(fn() {
    self.host.run_guarded(fn() raise Quit {
      finish(builder.command_finished(runner, None))
    })
  })
  finish(builder.start_build(runner))
}

///|
/// Rebuilds the manifest if it is out of date; `done(rebuilt, error)`.
fn Ninja::rebuild_manifest(
  self : Ninja,
  done : (Bool, String) -> Unit raise Quit,
) -> Unit raise Quit {
  let input = self.options.input_file
  if input == "" {
    done(false, "empty path")
    return
  }
  let (path, _) = @moonja.canonicalize_path(input, platform=self.host.platform)
  guard self.state.lookup_node(path) is Some(node) else {
    done(false, "")
    return
  }
  let builder = self.new_builder()
  builder.add_target(node) catch {
    error => {
      done(false, error.message())
      return
    }
  }
  if builder.already_up_to_date() {
    // Not an error, but nothing was rebuilt.
    done(false, "")
    return
  }
  self.drive(builder, fn(status, message) raise Quit {
    if !(status is Success) {
      done(false, message)
    } else if !node.dirty() {
      // A restat cleaned the manifest: it was not really rebuilt.
      self.state.reset()
      done(false, "")
    } else {
      done(true, "")
    }
  })
}

///|
/// Gives each edge the duration of its last run, for the ETA (ninja's
/// `ParsePreviousElapsedTimes`).
fn Ninja::parse_previous_elapsed_times(self : Ninja) -> Unit {
  for edge in self.state.edges() {
    for out in edge.outputs() {
      if self.build_log.lookup_by_output(out.path()) is Some(entry) {
        edge.set_prev_elapsed_time_millis(
          (entry.end_time - entry.start_time).to_int64(),
        )
        break
      }
    }
  }
}

///|
/// The node for a command-line target; `foo.c^` means the first output
/// built from foo.c (ninja's `CollectTarget`).
fn Ninja::collect_target(
  self : Ninja,
  target : String,
) -> @moonja.Node raise @moonja.NinjaError {
  if target == "" {
    raise @moonja.NinjaError::Error("empty path")
  }
  let platform = self.host.platform
  let (canonical, slash_bits) = @moonja.canonicalize_path(target, platform~)
  let (path, first_dependent) = if canonical.has_suffix("^") {
    (canonical.unsafe_substring(start=0, end=canonical.length() - 1), true)
  } else {
    (canonical, false)
  }
  guard self.state.lookup_node(path) is Some(node) else {
    let mut message = "unknown target '\{@moonja.decanonicalize_path(path, slash_bits, platform~)}'"
    if path == "clean" {
      message += ", did you mean 'ninja -t clean'?"
    } else if path == "help" {
      message += ", did you mean 'ninja -h'?"
    } else if self.state.spellcheck_node(path) is Some(suggestion) {
      message += ", did you mean '\{suggestion.path()}'?"
    }
    raise @moonja.NinjaError::Error(message)
  }
  if !first_dependent {
    return node
  }
  if node.out_edges().is_empty() {
    match self.deps_log.get_first_reverse_deps_node(node) {
      Some(dependent) => dependent
      None => raise @moonja.NinjaError::Error("'\{path}' has no out edge")
    }
  } else {
    let edge = node.out_edges()[0]
    if edge.outputs().is_empty() {
      self.host.fatal_no_raise("edge has no outputs")
    }
    edge.outputs()[0]
  }
}

///|
/// The targets named on the command line, or the default ones.
fn Ninja::collect_targets(
  self : Ninja,
  args : Array[String],
) -> Array[@moonja.Node] raise @moonja.NinjaError {
  if args.is_empty() {
    return self.state.default_nodes()
  }
  args.map(fn(arg) raise @moonja.NinjaError { self.collect_target(arg) })
}

///|
/// Builds the requested targets, then calls `done` with the exit code
/// (ninja's `RunBuild`).
fn Ninja::run_build(
  self : Ninja,
  done : (Int32) -> Unit raise Quit,
) -> Unit raise Quit {
  let targets = self.collect_targets(self.options.args) catch {
    error => {
      self.error(error.message())
      done(1)
      return
    }
  }
  let builder = self.new_builder()
  for target in targets {
    builder.add_target(target) catch {
      error => {
        self.error(error.message())
        done(1)
        return
      }
    }
  }
  if builder.already_up_to_date() {
    if !(self.config.verbosity is NoStatusUpdate) {
      @moonja.Status::info(self.status, "no work to do.")
    }
    done(0)
    return
  }
  self.drive(builder, fn(status, message) raise Quit {
    if !(status is Success) {
      @moonja.Status::info(self.status, "build stopped: \{message}.")
      if message.contains("interrupted by user") {
        done(130)
        return
      }
    }
    done(status.code())
  })
}
