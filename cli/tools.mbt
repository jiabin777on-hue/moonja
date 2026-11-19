// The subtools of ninja v1.13.2 src/ninja.cc (Apache-2.0, see NOTICE).

///|
/// What a tool's getopt found: options in order ('?' for an error, already
/// reported) and the operands.
priv struct ToolArgs {
  flags : Array[(UInt16, String)]
  operands : Array[String]
}

///|
/// A tool's long option: name, its short equivalent, whether it takes an
/// argument.
priv struct LongOption {
  name : String
  flag : UInt16
  has_arg : Bool
}

///|
/// getopt / getopt_long for a tool's arguments. Like glibc (and ninja's
/// getopt on Windows) options may follow operands, and `--` ends them.
/// Errors name the tool's argv[0], as ninja's tools reset getopt with it.
fn Ninja::tool_getopt(
  self : Ninja,
  args : Array[String],
  shortopts : String,
  longopts~ : Array[LongOption] = [],
) -> ToolArgs {
  let prog = self.options.tool_argv0
  let windows = self.host.platform is Windows
  let err = fn(text : String) { self.host.terminal.write_err(text) }
  let flags : Array[(UInt16, String)] = []
  let operands = []
  let takes_arg = fn(c : UInt16) -> Bool? {
    match shortopts.find(c.to_int().unsafe_to_char().to_string()) {
      Some(i) =>
        Some(i + 1 < shortopts.length() && shortopts.unsafe_get(i + 1) == ':')
      None => None
    }
  }
  let len = args.length()
  let mut i = 0
  while i < len {
    let arg = args[i]
    i += 1
    if arg == "--" {
      for j in i..<len {
        operands.push(args[j])
      }
      break
    }
    if arg.has_prefix("--") && !longopts.is_empty() {
      let body = arg.unsafe_substring(start=2, end=arg.length())
      let (name, value) = match body.find("=") {
        Some(eq) =>
          (
            body.unsafe_substring(start=0, end=eq),
            Some(body.unsafe_substring(start=eq + 1, end=body.length())),
          )
        None => (body, None)
      }
      let matches = longopts.filter(fn(o) { o.name.has_prefix(name) })
      let exact = longopts.filter(fn(o) { o.name == name })
      let chosen = if !exact.is_empty() {
        Some(exact[0])
      } else if matches.length() == 1 {
        Some(matches[0])
      } else {
        None
      }
      guard chosen is Some(option) else {
        if matches.length() > 1 {
          err("\{prog}: option '--\{name}' is ambiguous\n")
        } else {
          err("\{prog}: unrecognized option '\{arg}'\n")
        }
        flags.push(('?', ""))
        return { flags, operands, }
      }
      if option.has_arg {
        match value {
          Some(v) => flags.push((option.flag, v))
          None =>
            if i < len {
              flags.push((option.flag, args[i]))
              i += 1
            } else {
              err("\{prog}: option '--\{option.name}' requires an argument\n")
              flags.push(('?', ""))
              return { flags, operands, }
            }
        }
      } else if value is Some(_) {
        err("\{prog}: option '--\{option.name}' doesn't allow an argument\n")
        flags.push(('?', ""))
        return { flags, operands, }
      } else {
        flags.push((option.flag, ""))
      }
      continue
    }
    if arg.length() > 1 && arg.unsafe_get(0) == '-' {
      let mut j = if arg.has_prefix("--") { 2 } else { 1 }
      while j < arg.length() {
        let c = arg.unsafe_get(j)
        j += 1
        let flag = c.to_int().unsafe_to_char()
        match takes_arg(c) {
          None => {
            err(
              if windows {
                "\{prog}: invalid option -- `-\{flag}'\n"
              } else {
                "\{prog}: invalid option -- '\{flag}'\n"
              },
            )
            flags.push(('?', ""))
            return { flags, operands, }
          }
          Some(false) => flags.push((c, ""))
          Some(true) => {
            if windows && j < arg.length() && arg.unsafe_get(j) == '=' {
              j += 1
            }
            if j < arg.length() {
              flags.push((c, arg.unsafe_substring(start=j, end=arg.length())))
            } else if i < len {
              flags.push((c, args[i]))
              i += 1
            } else {
              err(
                if windows {
                  "\{prog}: argument required for option `-\{flag}'\n"
                } else {
                  "\{prog}: option requires an argument -- '\{flag}'\n"
                },
              )
              flags.push(('?', ""))
              return { flags, operands, }
            }
            break
          }
        }
      }
      continue
    }
    operands.push(arg)
  }
  { flags, operands, }
}

///|
fn Ninja::print(self : Ninja, text : String) -> Unit {
  self.host.print(text)
}

///|
/// Runs a subtool and returns its exit code.
fn Ninja::run_tool(self : Ninja, tool : ToolInfo) -> Int32 raise Quit {
  let args = self.options.args
  match tool.name {
    "browse" => {
      self.host.fatal("browse tool not supported on this platform")
      1
    }
    "msvc" => {
      self.host.fatal("the msvc tool is not supported by moonja")
      1
    }
    "clean" => self.tool_clean(args)
    "commands" => self.tool_commands(args)
    "inputs" => self.tool_inputs(args)
    "multi-inputs" => self.tool_multi_inputs(args)
    "deps" => self.tool_deps(args)
    "missingdeps" => self.tool_missing_deps(args)
    "graph" => self.tool_graph(args)
    "query" => self.tool_query(args)
    "targets" => self.tool_targets(args)
    "compdb" => self.tool_compdb(args)
    "compdb-targets" => self.tool_compdb_targets(args)
    "recompact" => self.tool_recompact()
    "restat" => self.tool_restat(args)
    "rules" => self.tool_rules(args)
    "cleandead" => self.tool_clean_dead()
    "urtle" => self.tool_urtle()
    "wincodepage" => self.tool_wincodepage(args)
    _ => {
      self.host.fatal("unknown tool '\{tool.name}'")
      1
    }
  }
}

///|
/// The targets named, or the defaults; an error message on failure.
fn Ninja::targets_or_error(
  self : Ninja,
  args : Array[String],
) -> Array[@moonja.Node]? {
  Some(self.collect_targets(args)) catch {
    error => {
      self.error(error.message())
      None
    }
  }
}

///|
fn Ninja::tool_graph(self : Ninja, args : Array[String]) -> Int32 {
  guard self.targets_or_error(args) is Some(nodes) else { return 1 }
  let graph = @moonja.GraphViz::new(
    self.state,
    fn(text) { self.print(text) },
    reader=self.host.files,
    warn=fn(text) { self.warning(text) },
  )
  graph.start()
  for node in nodes {
    graph.add_target(node)
  }
  graph.finish()
  0
}

///|
fn Ninja::tool_query(self : Ninja, args : Array[String]) -> Int32 {
  if args.is_empty() {
    self.error("expected a target to query")
    return 1
  }
  for arg in args {
    let node = self.collect_target(arg) catch {
      error => {
        self.error(error.message())
        return 1
      }
    }
    self.print("\{node.path()}:\n")
    if node.in_edge() is Some(edge) {
      if edge.dyndep() is Some(dyndep) && dyndep.dyndep_pending() {
        @moonja.load_dyndeps(self.state, self.host.files, dyndep) catch {
          error => self.warning("\{error.message()}\n")
        }
      }
      self.print("  input: \{edge.rule().name()}\n")
      for i, input in edge.inputs() {
        let label = if edge.is_implicit(i) {
          "| "
        } else if edge.is_order_only(i) {
          "|| "
        } else {
          ""
        }
        self.print("    \{label}\{input.path()}\n")
      }
      if !edge.validations().is_empty() {
        self.print("  validations:\n")
        for v in edge.validations() {
          self.print("    \{v.path()}\n")
        }
      }
    }
    self.print("  outputs:\n")
    for edge in node.out_edges() {
      for out in edge.outputs() {
        self.print("    \{out.path()}\n")
      }
    }
    let validation_edges = node.validation_out_edges()
    if !validation_edges.is_empty() {
      self.print("  validation for:\n")
      for edge in validation_edges {
        for out in edge.outputs() {
          self.print("    \{out.path()}\n")
        }
      }
    }
  }
  0
}

///|
fn Ninja::targets_list(
  self : Ninja,
  nodes : Array[@moonja.Node],
  depth : Int32,
  indent : Int32,
) -> Unit {
  for node in nodes {
    self.print("  ".repeat(indent))
    match node.in_edge() {
      Some(edge) => {
        self.print("\{node.path()}: \{edge.rule().name()}\n")
        if depth > 1 || depth <= 0 {
          self.targets_list(edge.inputs(), depth - 1, indent + 1)
        }
      }
      None => self.print("\{node.path()}\n")
    }
  }
}

///|
fn Ninja::tool_targets(self : Ninja, args : Array[String]) -> Int32 {
  let mut depth = 1
  if args.length() >= 1 {
    match args[0] {
      "rule" => {
        let rule = if args.length() > 1 { args[1] } else { "" }
        if rule == "" {
          // Source files: inputs nothing builds.
          for edge in self.state.edges() {
            for input in edge.inputs() {
              if input.in_edge() is None {
                self.print("\{input.path()}\n")
              }
            }
          }
        } else {
          let outputs : Map[String, Unit] = Map([])
          for edge in self.state.edges() {
            if edge.rule().name() == rule {
              for out in edge.outputs() {
                outputs[out.path()] = ()
              }
            }
          }
          let sorted = outputs.keys().collect()
          sorted.sort_by(@moonja.compare_lexical)
          for path in sorted {
            self.print("\{path}\n")
          }
        }
        return 0
      }
      "depth" => if args.length() > 1 { depth = @moonja.atoi(args[1]) }
      "all" => {
        for edge in self.state.edges() {
          for out in edge.outputs() {
            self.print("\{out.path()}: \{edge.rule().name()}\n")
          }
        }
        return 0
      }
      mode => {
        match spellcheck_string(mode, ["rule", "depth", "all"]) {
          Some(suggestion) =>
            self.error(
              "unknown target tool mode '\{mode}', did you mean '\{suggestion}'?",
            )
          None => self.error("unknown target tool mode '\{mode}'")
        }
        return 1
      }
    }
  }
  let roots = self.state.root_nodes() catch {
    error => {
      self.error(error.message())
      return 1
    }
  }
  self.targets_list(roots, depth, 0)
  0
}

///|
fn Ninja::tool_deps(self : Ninja, args : Array[String]) -> Int32 {
  let nodes = if args.is_empty() {
    self.deps_log
    .nodes()
    .filter(fn(n) { @moonja.is_deps_entry_live_for(n) catch { _ => false } })
  } else {
    guard self.targets_or_error(args) is Some(nodes) else { return 1 }
    nodes
  }
  for node in nodes {
    guard self.deps_log.get_deps(node) is Some(deps) else {
      self.print("\{node.path()}: deps not found\n")
      continue
    }
    let mtime = self.host.disk.stat(node.path()) catch {
      error => {
        self.error(error.message())
        -1
      }
    }
    let state = if mtime == 0 || mtime > deps.mtime() {
      "STALE"
    } else {
      "VALID"
    }
    self.print(
      "\{node.path()}: #deps \{deps.nodes().length()}, deps mtime \{deps.mtime()} (\{state})\n",
    )
    for dep in deps.nodes() {
      self.print("    \{dep.path()}\n")
    }
    self.print("\n")
  }
  0
}

///|
fn Ninja::tool_missing_deps(self : Ninja, args : Array[String]) -> Int32 {
  guard self.targets_or_error(args) is Some(nodes) else { return 1 }
  let scanner = @moonja.MissingDependencyScanner::new(
    self.deps_log,
    self.state,
    self.host.disk,
    on_missing_dep=fn(node, path, rule) {
      self.print(@moonja.missing_dep_message(node, path, rule))
    },
  )
  for node in nodes {
    scanner.process_node(node)
  }
  self.print(scanner.stats())
  if scanner.had_missing_deps() {
    3
  } else {
    0
  }
}

///|
fn Ninja::tool_rules(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "hd")
  let mut print_description = false
  for flag in parsed.flags {
    match flag.0 {
      'd' => print_description = true
      _ => {
        self.print(
          "usage: ninja -t rules [options]\n\noptions:\n  -d     also print the description of the rule\n  -h     print this message\n",
        )
        return 1
      }
    }
  }
  for rule in self.state.bindings().rules() {
    self.print(rule.name())
    if print_description && rule.get_binding("description") is Some(d) {
      self.print(": \{d.unparse()}")
    }
    self.print("\n")
  }
  0
}

///|
fn Ninja::print_commands(
  self : Ninja,
  edge : @moonja.Edge?,
  seen : Map[Int32, Unit],
  all : Bool,
) -> Unit {
  guard edge is Some(edge) else { return }
  if seen.contains(edge.id()) {
    return
  }
  seen[edge.id()] = ()
  if all {
    for input in edge.inputs() {
      self.print_commands(input.in_edge(), seen, all)
    }
  }
  if !edge.is_phony() {
    let command = edge.evaluate_command() catch { _ => "" }
    self.print("\{command}\n")
  }
}

///|
fn Ninja::tool_commands(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "hs")
  let mut all = true
  for flag in parsed.flags {
    match flag.0 {
      's' => all = false
      _ => {
        self.print(
          "usage: ninja -t commands [options] [targets]\n\noptions:\n  -s     only print the final command to build [target], not the whole chain\n",
        )
        return 1
      }
    }
  }
  guard self.targets_or_error(parsed.operands) is Some(nodes) else { return 1 }
  let seen = Map([])
  for node in nodes {
    self.print_commands(node.in_edge(), seen, all)
  }
  0
}

///|
fn Ninja::tool_inputs(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "h0Ed", longopts=[
    { name: "help", flag: 'h', has_arg: false, },
    { name: "no-shell-escape", flag: 'E', has_arg: false, },
    { name: "print0", flag: '0', has_arg: false, },
    { name: "dependency-order", flag: 'd', has_arg: false, },
  ])
  let mut print0 = false
  let mut escape = true
  let mut dependency_order = false
  for flag in parsed.flags {
    match flag.0 {
      'd' => dependency_order = true
      'E' => escape = false
      '0' => print0 = true
      _ => {
        self.print(
          "Usage '-t inputs [options] [targets]\n\nList all inputs used for a set of targets, sorted in dependency order.\nNote that by default, results are shell escaped, and sorted alphabetically,\nand never include validation target paths.\n\nOptions:\n  -h, --help          Print this message.\n  -0, --print0            Use \\0, instead of \\n as a line terminator.\n  -E, --no-shell-escape   Do not shell escape the result.\n  -d, --dependency-order  Sort results by dependency order.\n",
        )
        return 1
      }
    }
  }
  guard self.targets_or_error(parsed.operands) is Some(nodes) else { return 1 }
  let collector = @moonja.InputsCollector::new(platform=self.host.platform)
  for node in nodes {
    collector.visit_node(node)
  }
  let inputs = collector.inputs_as_strings(escape~)
  if !dependency_order {
    inputs.sort_by(@moonja.compare_lexical)
  }
  for input in inputs {
    self.print(if print0 { input + "\u{0}" } else { input + "\n" })
  }
  0
}

///|
fn Ninja::tool_multi_inputs(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "d:h0", longopts=[
    { name: "help", flag: 'h', has_arg: false, },
    { name: "delimiter", flag: 'd', has_arg: true, },
    { name: "print0", flag: '0', has_arg: false, },
  ])
  let mut terminator = "\n"
  let mut delimiter = "\t"
  for flag in parsed.flags {
    match flag.0 {
      'd' => delimiter = flag.1
      '0' => terminator = "\u{0}"
      _ => {
        self.print(
          "Usage '-t multi-inputs [options] [targets]\n\nPrint one or more sets of inputs required to build targets, sorted in dependency order.\nThe tool works like inputs tool but with addition of the target for each line.\nThe output will be a series of lines with the following elements:\n<target> <delimiter> <input> <terminator>\nNote that a given input may appear for several targets if it is used by more than one targets.\nOptions:\n  -h, --help                   Print this message.\n  -d  --delimiter=DELIM        Use DELIM instead of TAB for field delimiter.\n  -0, --print0                 Use \\0, instead of \\n as a line terminator.\n",
        )
        return 1
      }
    }
  }
  guard self.targets_or_error(parsed.operands) is Some(nodes) else { return 1 }
  for node in nodes {
    let collector = @moonja.InputsCollector::new(platform=self.host.platform)
    collector.visit_node(node)
    for input in collector.inputs_as_strings() {
      self.print("\{node.path()}\{delimiter}\{input}\{terminator}")
    }
  }
  0
}

///|
fn Ninja::tool_clean(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "hgr")
  let mut generator = false
  let mut clean_rules = false
  for flag in parsed.flags {
    match flag.0 {
      'g' => generator = true
      'r' => clean_rules = true
      _ => {
        self.print(
          "usage: ninja -t clean [options] [targets]\n\noptions:\n  -g     also clean files marked as ninja generator output\n  -r     interpret targets as a list of rules to clean instead\n",
        )
        return 1
      }
    }
  }
  let targets = parsed.operands
  if clean_rules && targets.is_empty() {
    self.error("expected a rule to clean")
    return 1
  }
  let cleaner = self.cleaner()
  if targets.is_empty() {
    cleaner.clean_all(generator~)
  } else if clean_rules {
    cleaner.clean_rules(targets)
  } else {
    cleaner.clean_targets(targets)
  }
}

///|
fn Ninja::cleaner(self : Ninja) -> @moonja.Cleaner {
  @moonja.Cleaner::new(
    self.state,
    self.config,
    self.host.disk,
    reader=self.host.files,
    terminal=self.host.terminal,
  )
}

///|
fn Ninja::tool_clean_dead(self : Ninja) -> Int32 {
  self.cleaner().clean_dead(self.build_log.entries())
}

///|
/// The command, with an `@rspfile`, `-f rspfile` or `--option-file=rspfile`
/// argument replaced by the response file's contents (`compdb -x`).
fn expand_rspfile(edge : @moonja.Edge, expand : Bool) -> String {
  let command = edge.evaluate_command() catch { _ => "" }
  if !expand {
    return command
  }
  let rspfile = edge.get_unescaped_rspfile() catch { _ => "" }
  if rspfile == "" {
    return command
  }
  guard command.find(rspfile) is Some(index) && index != 0 else {
    return command
  }
  let at = command.unsafe_get(index - 1) == '@'
  let dash_f = command.find("-f ") == Some(index - 3)
  let option_file = command.find("--option-file=") == Some(index - 14)
  if !at && !dash_f && !option_file {
    return command
  }
  let content = (edge.get_binding("rspfile_content") catch { _ => "" }).replace_all(
    old="\n",
    new=" ",
  )
  let (start, len) = if at {
    (index - 1, rspfile.length() + 1)
  } else if dash_f {
    (index - 3, rspfile.length() + 3)
  } else {
    (index - 14, rspfile.length() + 14)
  }
  command.unsafe_substring(start=0, end=start) +
  content +
  command.unsafe_substring(start=start + len, end=command.length())
}

///|
fn Ninja::compdb_object(
  self : Ninja,
  directory : String,
  edge : @moonja.Edge,
  expand : Bool,
) -> Unit {
  let json = @moonja.encode_json_string
  self.print(
    "\n  {\n    \"directory\": \"\{json(directory)}\",\n    \"command\": \"\{json(expand_rspfile(edge, expand))}\",\n    \"file\": \"\{json(edge.inputs()[0].path())}\",\n    \"output\": \"\{json(edge.outputs()[0].path())}\"\n  }",
  )
}

///|
fn Ninja::tool_compdb(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "hx")
  let mut expand = false
  for flag in parsed.flags {
    match flag.0 {
      'x' => expand = true
      _ => {
        self.print(
          "usage: ninja -t compdb [options] [rules]\n\noptions:\n  -x     expand @rspfile style response file invocations\n",
        )
        return 1
      }
    }
  }
  let rules = parsed.operands
  let directory = (self.host.cwd)()
  let mut first = true
  self.print("[")
  for edge in self.state.edges() {
    if edge.inputs().is_empty() {
      continue
    }
    for _ in 0..<(if rules.is_empty() { 1 } else { 0 }) {
      if !first {
        self.print(",")
      }
      self.compdb_object(directory, edge, expand)
      first = false
    }
    for rule in rules {
      if edge.rule().name() == rule {
        if !first {
          self.print(",")
        }
        self.compdb_object(directory, edge, expand)
        first = false
      }
    }
  }
  self.print("\n]\n")
  0
}

///|
fn Ninja::tool_compdb_targets(
  self : Ninja,
  args : Array[String],
) -> Int32 raise Quit {
  let parsed = self.tool_getopt(args, "hx")
  let mut expand = false
  let mut help = false
  for flag in parsed.flags {
    match flag.0 {
      'x' => expand = true
      _ => {
        help = true
        break
      }
    }
  }
  if !help && parsed.operands.is_empty() {
    self.error("compdb-targets expects the name of at least one target")
    help = true
  }
  if help {
    self.print(
      "usage: ninja -t compdb [-hx] target [targets]\n\noptions:\n  -h     display this help message\n  -x     expand @rspfile style response file invocations\n",
    )
    return 1
  }
  let collector = @moonja.CommandCollector::new()
  for target in parsed.operands {
    let node = self.collect_target(target) catch {
      error => {
        self.host.fatal(error.message())
        return 1
      }
    }
    if node.in_edge() is None {
      self.host.fatal(
        "'\{node.path()}' is not a target (i.e. it is not an output of any `build` statement)",
      )
    }
    collector.collect_from(node)
  }
  let directory = (self.host.cwd)()
  self.print("[")
  let mut first = true
  for edge in collector.in_edges() {
    if edge.is_phony() || edge.inputs().is_empty() {
      continue
    }
    if !first {
      self.print(",")
    }
    self.compdb_object(directory, edge, expand)
    first = false
  }
  self.print("\n]\n")
  0
}

///|
fn Ninja::tool_recompact(self : Ninja) -> Int32 {
  if !self.ensure_build_dir_exists() {
    return 1
  }
  if !self.open_build_log(true) || !self.open_deps_log(true) {
    return 1
  }
  0
}

///|
fn Ninja::tool_restat(self : Ninja, args : Array[String]) -> Int32 {
  let parsed = self.tool_getopt(args, "h")
  if !parsed.flags.is_empty() {
    self.print("usage: ninja -t restat [outputs]\n")
    return 1
  }
  // The manifest is not loaded, so this is always ./.ninja_log.
  if !self.ensure_build_dir_exists() {
    return 1
  }
  let path = self.log_path(".ninja_log")
  let (status, warning) = self.build_log.load(self.host.disk, path) catch {
    error => {
      self.error("loading build log \{path}: \{error.message()}")
      return 1
    }
  }
  if status is @moonja.LoadStatus::NotFound {
    // Nothing to restat.
    return 0
  }
  if warning != "" {
    self.warning(warning)
  }
  self.build_log.restat(self.host.disk, path, parsed.operands) catch {
    error => {
      self.error("failed recompaction: \{error.message()}")
      return 1
    }
  }
  if !self.config.dry_run {
    self.build_log.open_for_write(self.host.disk, path, fn(p) {
      self.is_path_dead(p)
    }) catch {
      error => {
        self.error("opening build log: \{error.message()}")
        return 1
      }
    }
  }
  0
}

///|
fn Ninja::tool_wincodepage(self : Ninja, args : Array[String]) -> Int32 {
  if !args.is_empty() {
    self.print("usage: ninja -t wincodepage\n")
    return 1
  }
  // Node.js reads and writes UTF-8, like a ninja built with a UTF-8
  // manifest.
  self.print("Build file encoding: UTF-8\n")
  0
}

///|
/// The urtle, run-length encoded.
let urtle : String = " 13 ,3;2!2;\n8 ,;<11!;\n5 `'<10!(2`'2!\n11 ,6;, `\\. `\\9 .,c13$ec,.\n6 " +
  ",2;11!>; `. ,;!2> .e8$2\".2 \"?7$e.\n <:<8!'` 2.3,.2` ,3!' ;,(?7\";2!2'<" +
  "; `?6$PF ,;,\n2 `'4!8;<!3'`2 3! ;,`'2`2'3!;4!`2.`!;2 3,2 .<!2'`).\n5 3`5" +
  "'2`9 `!2 `4!><3;5! J2$b,`!>;2!:2!`,d?b`!>\n26 `'-;,(<9!> $F3 )3.:!.2 d\"" +
  "2 ) !>\n30 7`2'<3!- \"=-='5 .2 `2-=\",!>\n25 .ze9$er2 .,cd16$bc.'\n22 .e" +
  "14$,26$.\n21 z45$c .\n20 J50$c\n20 14$P\"`?34$b\n20 14$ dbc `2\"?22$?7$c" +
  "\n20 ?18$c.6 4\"8?4\" c8$P\n9 .2,.8 \"20$c.3 ._14 J9$\n .2,2c9$bec,.2 `?" +
  "21$c.3`4%,3%,3 c8$P\"\n22$c2 2\"?21$bc2,.2` .2,c7$P2\",cb\n23$b bc,.2\"2" +
  "?14$2F2\"5?2\",J5$P\" ,zd3$\n24$ ?$3?%3 `2\"2?12$bcucd3$P3\"2 2=7$\n23$P" +
  "\" ,3;<5!>2;,. `4\"6?2\"2 ,9;, `\"?2$\n"

///|
fn Ninja::tool_urtle(self : Ninja) -> Int32 {
  let out = StringBuilder()
  let mut count = 0
  for c in urtle {
    if c >= '0' && c <= '9' {
      count = count * 10 + (c.to_int() - '0'.to_int())
    } else {
      for _ in 0..<@cmp.maximum(count, 1) {
        out.write_char(c)
      }
      count = 0
    }
  }
  self.print(out.to_string())
  0
}
