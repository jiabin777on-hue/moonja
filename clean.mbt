// Ported from ninja v1.13.2 src/clean.cc (Apache-2.0, see NOTICE).

///|
/// Removes built files: `ninja -t clean` and `-t cleandead` (ninja's
/// `Cleaner`). Each `clean_*` method returns 0, or 1 if something could not
/// be removed or was not found.
pub struct Cleaner {
  state : State
  config : BuildConfig
  disk : &Disk
  /// Reads dyndep files, which may name more outputs.
  reader : &FileReader?
  terminal : &Terminal?
  removed : Map[String, Unit]
  cleaned : Map[Int32, Unit]
  mut cleaned_files_count : Int32
  mut status : Int32
}

///|
pub fn Cleaner::new(
  state : State,
  config : BuildConfig,
  disk : &Disk,
  reader? : &FileReader,
  terminal? : &Terminal,
) -> Cleaner {
  {
    state,
    config,
    disk,
    reader,
    terminal,
    removed: Map([]),
    cleaned: Map([]),
    cleaned_files_count: 0,
    status: 0,
  }
}

///|
pub fn Cleaner::cleaned_files_count(self : Cleaner) -> Int32 {
  self.cleaned_files_count
}

///|
fn Cleaner::print(self : Cleaner, text : String) -> Unit {
  if self.terminal is Some(terminal) {
    terminal.write_out(text)
  }
}

///|
fn Cleaner::error(self : Cleaner, message : String) -> Unit {
  if self.terminal is Some(terminal) {
    terminal.write_err("ninja: error: \{message}\n")
  }
}

///|
fn Cleaner::is_verbose(self : Cleaner) -> Bool {
  !(self.config.verbosity is Quiet) &&
  (self.config.verbosity is Verbose || self.config.dry_run)
}

///|
fn Cleaner::file_exists(self : Cleaner, path : String) -> Bool {
  let mtime = self.disk.stat(path) catch {
    error => {
      self.error(error.message())
      -1
    }
  }
  // A failed stat counts as "does not exist".
  mtime > 0
}

///|
fn Cleaner::report(self : Cleaner, path : String) -> Unit {
  self.cleaned_files_count += 1
  if self.is_verbose() {
    self.print("Remove \{path}\n")
  }
}

///|
fn Cleaner::remove(self : Cleaner, path : String) -> Unit {
  if self.removed.contains(path) {
    return
  }
  self.removed[path] = ()
  if self.config.dry_run {
    if self.file_exists(path) {
      self.report(path)
    }
  } else {
    match self.disk.remove_file(path) {
      0 => self.report(path)
      -1 => self.status = 1
      _ => ()
    }
  }
}

///|
fn Cleaner::remove_edge_files(self : Cleaner, edge : Edge) -> Unit {
  let depfile = edge.get_unescaped_depfile() catch { _ => "" }
  if depfile != "" {
    self.remove(depfile)
  }
  let rspfile = edge.get_unescaped_rspfile() catch { _ => "" }
  if rspfile != "" {
    self.remove(rspfile)
  }
}

///|
fn Cleaner::print_header(self : Cleaner) -> Unit {
  if self.config.verbosity is Quiet {
    return
  }
  self.print(if self.is_verbose() { "Cleaning...\n" } else { "Cleaning... " })
}

///|
fn Cleaner::print_footer(self : Cleaner) -> Unit {
  if self.config.verbosity is Quiet {
    return
  }
  self.print("\{self.cleaned_files_count} files.\n")
}

///|
fn Cleaner::reset(self : Cleaner) -> Unit {
  self.status = 0
  self.cleaned_files_count = 0
  self.removed.clear()
  self.cleaned.clear()
}

///|
/// Loads the dyndep files that exist before cleaning them: they may name
/// more outputs. Errors are ignored; we clean what we know.
fn Cleaner::load_dyndeps(self : Cleaner) -> Unit {
  guard self.reader is Some(reader) else { return }
  for edge in self.state.edges {
    if edge.dyndep is Some(dyndep) && dyndep.dyndep_pending {
      load_dyndeps(self.state, reader, dyndep) catch {
        _ => ()
      }
    }
  }
}

///|
/// Removes every output but phony ones, and generator outputs unless
/// `generator` is set.
pub fn Cleaner::clean_all(self : Cleaner, generator~ : Bool = false) -> Int32 {
  self.reset()
  self.print_header()
  self.load_dyndeps()
  for edge in self.state.edges {
    if edge.is_phony() {
      continue
    }
    if !generator && (edge.get_binding_bool("generator") catch { _ => false }) {
      continue
    }
    for out in edge.outputs {
      self.remove(out.path)
    }
    self.remove_edge_files(edge)
  }
  self.print_footer()
  self.status
}

///|
/// Removes the build log's outputs that the manifest no longer mentions.
pub fn Cleaner::clean_dead(
  self : Cleaner,
  entries : Map[String, LogEntry],
) -> Int32 {
  self.reset()
  self.print_header()
  self.load_dyndeps()
  for path, _ in entries {
    // Stale: not in the graph at all, or only through an old deps log
    // entry, neither built nor used.
    match self.state.lookup_node(path) {
      None => self.remove(path)
      Some(node) =>
        if node.in_edge is None && node.out_edges.is_empty() {
          self.remove(path)
        }
    }
  }
  self.print_footer()
  self.status
}

///|
fn Cleaner::do_clean_target(self : Cleaner, target : Node) -> Unit {
  if target.in_edge is Some(edge) {
    if !edge.is_phony() {
      self.remove(target.path)
      self.remove_edge_files(edge)
    }
    for input in edge.inputs {
      if !self.cleaned.contains(input.index) {
        self.do_clean_target(input)
      }
    }
  }
  self.cleaned[target.index] = ()
}

///|
/// Removes `target` and everything it is built from.
pub fn Cleaner::clean_target_node(self : Cleaner, target : Node) -> Int32 {
  self.reset()
  self.print_header()
  self.load_dyndeps()
  self.do_clean_target(target)
  self.print_footer()
  self.status
}

///|
pub fn Cleaner::clean_target(self : Cleaner, target : String) -> Int32 {
  self.reset()
  match self.state.lookup_node(target) {
    Some(node) => ignore(self.clean_target_node(node))
    None => {
      self.error("unknown target '\{target}'")
      self.status = 1
    }
  }
  self.status
}

///|
pub fn Cleaner::clean_targets(self : Cleaner, targets : Array[String]) -> Int32 {
  self.reset()
  self.print_header()
  self.load_dyndeps()
  for name in targets {
    if name == "" {
      self.error("failed to canonicalize '': empty path")
      self.status = 1
      continue
    }
    let (path, _) = canonicalize_path(name, platform=self.state.platform)
    match self.state.lookup_node(path) {
      Some(target) => {
        if self.is_verbose() {
          self.print("Target \{path}\n")
        }
        self.do_clean_target(target)
      }
      None => {
        self.error("unknown target '\{path}'")
        self.status = 1
      }
    }
  }
  self.print_footer()
  self.status
}

///|
fn Cleaner::do_clean_rule(self : Cleaner, rule : Rule) -> Unit {
  for edge in self.state.edges {
    if edge.rule.name == rule.name {
      for out in edge.outputs {
        self.remove(out.path)
        self.remove_edge_files(edge)
      }
    }
  }
}

///|
pub fn Cleaner::clean_rule(self : Cleaner, name : String) -> Int32 {
  self.reset()
  match self.state.bindings.lookup_rule(name) {
    Some(rule) => {
      self.print_header()
      self.load_dyndeps()
      self.do_clean_rule(rule)
      self.print_footer()
    }
    None => {
      self.error("unknown rule '\{name}'")
      self.status = 1
    }
  }
  self.status
}

///|
pub fn Cleaner::clean_rules(self : Cleaner, names : Array[String]) -> Int32 {
  self.reset()
  self.print_header()
  self.load_dyndeps()
  for name in names {
    match self.state.bindings.lookup_rule(name) {
      Some(rule) => {
        if self.is_verbose() {
          self.print("Rule \{name}\n")
        }
        self.do_clean_rule(rule)
      }
      None => {
        self.error("unknown rule '\{name}'")
        self.status = 1
      }
    }
  }
  self.print_footer()
  self.status
}
