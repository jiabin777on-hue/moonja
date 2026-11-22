///|
/// Why nodes are dirty, for `-d explain` (ninja's `Explanations`).
pub struct Explanations {
  map : Map[String, Array[String]]
}

///|
pub fn Explanations::new() -> Explanations {
  { map: Map([]), }
}

///|
pub fn Explanations::record(
  self : Explanations,
  node : Node,
  message : String,
) -> Unit {
  match self.map.get(node.path) {
    Some(list) => list.push(message)
    None => self.map[node.path] = [message]
  }
}

///|
pub fn Explanations::lookup(self : Explanations, node : Node) -> Array[String] {
  self.map.get(node.path).unwrap_or([])
}

///|
fn record(explanations : Explanations?, node : Node, message : String) -> Unit {
  if explanations is Some(e) {
    e.record(node, message)
  }
}

///|
/// Reads a file through `disk` for parsers: missing files are errors.
fn disk_reader(disk : &Disk) -> (String) -> String raise NinjaError {
  fn(path : String) raise NinjaError {
    match disk.read_file(path) {
      Some(contents) => contents
      None => raise Error("No such file or directory")
    }
  }
}

///|
/// Adds the dependencies an edge discovered when it last ran: from the
/// deps log for `deps = gcc|msvc`, or from its `depfile`.
pub struct ImplicitDepLoader {
  state : State
  deps_log : DepsLog?
  disk : &Disk
  explanations : Explanations?
  /// When set, depfile deps are collected here and the graph is left alone
  /// (ninja's `NodeStoringImplicitDepLoader`, for `-t missingdeps`).
  store : Array[Node]?
}

///|
pub fn ImplicitDepLoader::new(
  state : State,
  disk : &Disk,
  deps_log? : DepsLog,
  explanations? : Explanations,
  store? : Array[Node],
) -> ImplicitDepLoader {
  { state, deps_log, disk, explanations, store, }
}

///|
/// Loads the edge's discovered deps. False when they are missing or stale,
/// so the edge must run to regenerate them.
pub fn ImplicitDepLoader::load_deps(
  self : ImplicitDepLoader,
  edge : Edge,
) -> Bool raise NinjaError {
  if edge.get_binding("deps") != "" {
    return self.load_deps_from_log(edge)
  }
  let depfile = edge.get_unescaped_depfile()
  if depfile != "" {
    return self.load_depfile(edge, depfile)
  }
  true
}

///|
fn ImplicitDepLoader::load_depfile(
  self : ImplicitDepLoader,
  edge : Edge,
  path : String,
) -> Bool raise NinjaError {
  let metric = metric_record("depfile load")
  defer metric.stop()
  // A missing depfile reads as empty.
  let content = self.disk.read_file(path) catch {
    error => raise Error("loading '\{path}': \{error.message()}")
  }
  let content = content.unwrap_or("")
  let first_output = edge.outputs[0]
  if content == "" {
    record(self.explanations, first_output, "depfile '\{path}' is missing")
    return false
  }
  let depfile = parse_depfile(content) catch {
    error => raise Error("\{path}: \{error.message()}")
  }
  if depfile.outs.is_empty() {
    raise Error("\{path}: no outputs declared")
  }
  let (primary, _) = canonicalize_path(
    depfile.outs[0],
    platform=self.state.platform,
  )
  // A depfile for another output makes the edge dirty.
  if first_output.path != primary {
    record(
      self.explanations,
      first_output,
      "expected depfile '\{path}' to mention '\{first_output.path}', got '\{primary}'",
    )
    return false
  }
  // Every output it mentions must be an output of the edge. ninja compares
  // the first one canonicalized and the others as written.
  for i, out in depfile.outs {
    let out = if i == 0 { primary } else { out }
    if !edge.outputs.iter().any(fn(node) { node.path == out }) {
      raise Error(
        "\{path}: depfile mentions '\{out}' as an output, but no such output was declared",
      )
    }
  }
  self.process_depfile_deps(edge, depfile.ins)
  true
}

///|
fn ImplicitDepLoader::process_depfile_deps(
  self : ImplicitDepLoader,
  edge : Edge,
  ins : Array[String],
) -> Unit {
  if self.store is Some(store) {
    for input in ins {
      let (path, slash_bits) = canonicalize_path(
        input,
        platform=self.state.platform,
      )
      store.push(self.state.get_node(path, slash_bits))
    }
    return
  }
  // The new deps go before the order-only ones.
  let at = edge.inputs.length() - edge.order_only_deps
  for i, input in ins {
    let (path, slash_bits) = canonicalize_path(
      input,
      platform=self.state.platform,
    )
    let node = self.state.get_node(path, slash_bits)
    edge.inputs.insert(at + i, node)
    node.out_edges.push(edge)
  }
  edge.implicit_deps += ins.length()
}

///|
fn ImplicitDepLoader::load_deps_from_log(
  self : ImplicitDepLoader,
  edge : Edge,
) -> Bool {
  // Deps are only supported for single-output edges.
  let output = edge.outputs[0]
  let deps = match self.deps_log {
    Some(log) => log.get_deps(output)
    None => None
  }
  guard deps is Some(deps) else {
    record(self.explanations, output, "deps for '\{output.path}' are missing")
    return false
  }
  // Deps older than the output are stale.
  if output.mtime > deps.mtime {
    record(
      self.explanations,
      output,
      "stored deps info out of date for '\{output.path}' (\{deps.mtime} vs \{output.mtime})",
    )
    return false
  }
  let at = edge.inputs.length() - edge.order_only_deps
  for i, node in deps.nodes {
    edge.inputs.insert(at + i, node)
  }
  edge.implicit_deps += deps.nodes.length()
  for node in deps.nodes {
    node.out_edges.push(edge)
  }
  true
}

///|
/// Decides which nodes are dirty: port of ninja's `DependencyScan`.
pub struct DependencyScan {
  state : State
  mut build_log : BuildLog?
  disk : &Disk
  dep_loader : ImplicitDepLoader
  explanations : Explanations?
}

///|
pub fn DependencyScan::new(
  state : State,
  disk : &Disk,
  build_log? : BuildLog,
  deps_log? : DepsLog,
  explanations? : Explanations,
) -> DependencyScan {
  {
    state,
    build_log,
    disk,
    dep_loader: { state, deps_log, disk, explanations, store: None, },
    explanations,
  }
}

///|
pub fn DependencyScan::build_log(self : DependencyScan) -> BuildLog? {
  self.build_log
}

///|
pub fn DependencyScan::set_build_log(
  self : DependencyScan,
  log : BuildLog?,
) -> Unit {
  self.build_log = log
}

///|
pub fn DependencyScan::deps_log(self : DependencyScan) -> DepsLog? {
  self.dep_loader.deps_log
}

///|
/// Loads the dyndep file `node` into the graph.
pub fn DependencyScan::load_dyndeps(
  self : DependencyScan,
  node : Node,
  file~ : DyndepFile = DyndepFile::new(),
) -> Unit raise NinjaError {
  node.dyndep_pending = false
  record(self.explanations, node, "loading dyndep file '\{node.path}'")
  let parser : DyndepParser = {
    state: self.state,
    read: Some(disk_reader(self.disk)),
    file,
    lexer: Lexer::new(""),
    env: BindingEnv::new(),
  }
  parser.load(node.path)
  apply_dyndeps(node, file)
}

///|
/// Updates the edges that bind `node` as their dyndep file from `file`.
fn apply_dyndeps(node : Node, file : DyndepFile) -> Unit raise NinjaError {
  for edge in node.out_edges {
    match edge.dyndep {
      Some(dyndep) if physical_equal(dyndep, node) => ()
      _ => continue
    }
    guard file.entries.get(edge.id) is Some(dyndeps) else {
      raise Error(
        "'\{edge.outputs[0].path}' not mentioned in its dyndep file '\{node.path}'",
      )
    }
    dyndeps.used = true
    update_edge(edge, dyndeps)
  }
  let unused = file.entries.values().filter(fn(d) { !d.used }).collect()
  unused.sort_by(fn(a, b) { a.edge.id.compare(b.edge.id) })
  if unused is [first, ..] {
    raise Error(
      "dyndep file '\{node.path}' mentions output '\{first.edge.outputs[0].path}' whose build statement does not have a dyndep binding for the file",
    )
  }
}

///|
/// Updates the dirty state of `node` and everything it depends on. The
/// validation nodes found along the way are scanned too and appended to
/// `validation_nodes`.
pub fn DependencyScan::recompute_dirty(
  self : DependencyScan,
  initial : Node,
  validation_nodes~ : Array[Node] = [],
) -> Unit raise NinjaError {
  let stack : Array[Node] = []
  let nodes : @deque.Deque[Node] = @deque.Deque([])
  nodes.push_back(initial)
  while nodes.pop_front() is Some(node) {
    stack.clear()
    let found : Array[Node] = []
    self.recompute_node_dirty(node, stack, found)
    for v in found {
      nodes.push_back(v)
      validation_nodes.push(v)
    }
  }
}

///|
fn DependencyScan::recompute_node_dirty(
  self : DependencyScan,
  node : Node,
  stack : Array[Node],
  validation_nodes : Array[Node],
) -> Unit raise NinjaError {
  guard node.in_edge is Some(edge) else {
    // A leaf: done if seen before, otherwise dirty when missing.
    if node.status_known() {
      return
    }
    node.stat_if_necessary(self.disk)
    if !node.exists() {
      record(
        self.explanations,
        node,
        "\{node.path} has no in-edge and is missing",
      )
    }
    node.dirty = !node.exists()
    return
  }
  if edge.mark is VisitDone {
    return
  }
  self.verify_dag(node, stack)
  edge.mark = VisitInStack
  stack.push(node)
  let mut dirty = false
  edge.outputs_ready = true
  edge.deps_missing = false
  if !edge.deps_loaded {
    // First visit: load a pending dyndep file now if it is ready. If it
    // is not, the edge is not ready either; the build loads it later.
    match edge.dyndep {
      Some(dyndep) if dyndep.dyndep_pending => {
        self.recompute_node_dirty(dyndep, stack, validation_nodes)
        let ready = match dyndep.in_edge {
          None => true
          Some(producer) => producer.outputs_ready
        }
        if ready {
          self.load_dyndeps(dyndep)
        }
      }
      _ => ()
    }
  }
  // Output mtimes, to compare with the newest input below.
  for out in edge.outputs {
    out.stat_if_necessary(self.disk)
  }
  if !edge.deps_loaded {
    // First visit: load the discovered deps.
    edge.deps_loaded = true
    if !self.dep_loader.load_deps(edge) {
      // Missing deps info: rebuild to regenerate it.
      dirty = true
      edge.deps_missing = true
    }
  }
  // Validations are scanned separately, so that one depending on this node
  // does not look like a cycle.
  for v in edge.validations {
    validation_nodes.push(v)
  }
  let mut most_recent_input : Node? = None
  for i, input in edge.inputs {
    self.recompute_node_dirty(input, stack, validation_nodes)
    // An input that is not ready makes the outputs not ready.
    if input.in_edge is Some(producer) && !producer.outputs_ready {
      edge.outputs_ready = false
    }
    if !edge.is_order_only(i) {
      if input.dirty {
        record(self.explanations, node, "\{input.path} is dirty")
        dirty = true
      } else {
        match most_recent_input {
          Some(newest) if input.mtime <= newest.mtime => ()
          _ => most_recent_input = Some(input)
        }
      }
    }
  }
  if !dirty {
    dirty = self.recompute_outputs_dirty(edge, most_recent_input)
  }
  if dirty {
    for out in edge.outputs {
      out.dirty = true
    }
  }
  // A dirty edge's outputs are not ready, except for a phony edge without
  // inputs, which has nothing to do.
  if dirty && !(edge.is_phony() && edge.inputs.is_empty()) {
    edge.outputs_ready = false
  }
  edge.mark = VisitDone
  ignore(stack.pop())
}

///|
fn DependencyScan::verify_dag(
  self : DependencyScan,
  node : Node,
  stack : Array[Node],
) -> Unit raise NinjaError {
  ignore(self)
  guard node.in_edge is Some(edge) else { return }
  if !(edge.mark is VisitInStack) {
    return
  }
  // Find the edge on the stack, and report the cycle as starting and
  // ending at this node: `ninja b` on "build a b: cat c / build c: cat a"
  // says a -> c -> a, not b -> c -> a.
  let mut start = 0
  while start < stack.length() {
    match stack[start].in_edge {
      Some(e) if physical_equal(e, edge) => break
      _ => start += 1
    }
  }
  stack[start] = node
  let message = StringBuilder()
  message.write_string("dependency cycle: ")
  for i in start..<stack.length() {
    message.write_string(stack[i].path)
    message.write_string(" -> ")
  }
  message.write_string(stack[start].path)
  if start + 1 == stack.length() && edge.maybe_phonycycle_diagnostic() {
    // The parser keeps the self-reference only with phonycycle=err.
    message.write_string(" [-w phonycycle=err]")
  }
  raise Error(message.to_string())
}

///|
/// Whether any output of `edge` is out of date.
pub fn DependencyScan::recompute_outputs_dirty(
  self : DependencyScan,
  edge : Edge,
  most_recent_input : Node?,
) -> Bool raise NinjaError {
  let command = edge.evaluate_command(incl_rsp_file=true)
  for out in edge.outputs {
    if self.recompute_output_dirty(edge, most_recent_input, command, out) {
      return true
    }
  }
  false
}

///|
fn DependencyScan::recompute_output_dirty(
  self : DependencyScan,
  edge : Edge,
  most_recent_input : Node?,
  command : String,
  output : Node,
) -> Bool raise NinjaError {
  if edge.is_phony() {
    // Phony edges write nothing: their outputs are dirty only when there
    // are no inputs and the output is missing.
    if edge.inputs.is_empty() && !output.exists() {
      record(
        self.explanations,
        output,
        "output \{output.path} of phony edge with no inputs doesn't exist",
      )
      return true
    }
    // Dependents see the newest input's mtime on the phony output.
    if most_recent_input is Some(newest) {
      output.update_phony_mtime(newest.mtime)
    }
    return false
  }
  if !output.exists() {
    record(self.explanations, output, "output \{output.path} doesn't exist")
    return true
  }
  // A restat rule may have left its output untouched in an earlier run
  // and recorded the command's start time instead: compare the recorded
  // mtime, not the file's.
  let mut entry : LogEntry? = None
  let mut used_restat = false
  if edge.get_binding_bool("restat") && self.build_log is Some(log) {
    entry = log.lookup_by_output(output.path)
    used_restat = entry is Some(_)
  }
  if !used_restat && most_recent_input is Some(newest) {
    if output.mtime < newest.mtime {
      record(
        self.explanations,
        output,
        "output \{output.path} older than most recent input \{newest.path} (\{output.mtime} vs \{newest.mtime})",
      )
      return true
    }
  }
  if self.build_log is Some(log) {
    let generator = edge.get_binding_bool("generator")
    if entry is None {
      entry = log.lookup_by_output(output.path)
    }
    match entry {
      Some(e) => {
        // A changed command makes the output dirty, unless the rule is a
        // generator.
        if !generator && hash_command(command) != e.command_hash {
          record(
            self.explanations,
            output,
            "command line changed for \{output.path}",
          )
          return true
        }
        // A run that wrote the output but failed or was interrupted leaves
        // a recorded mtime older than the newest input.
        if most_recent_input is Some(newest) && e.mtime < newest.mtime {
          record(
            self.explanations,
            output,
            "recorded mtime of \{output.path} older than most recent input \{newest.path} (\{e.mtime} vs \{newest.mtime})",
          )
          return true
        }
      }
      None =>
        if !generator {
          record(
            self.explanations,
            output,
            "command line not found in log for \{output.path}",
          )
          return true
        }
    }
  }
  false
}

///|
/// Collects the inputs that lead to nodes, skipping outputs of phony
/// edges (`ninja -t inputs`).
pub struct InputsCollector {
  inputs : Array[Node]
  visited : Map[String, Unit]
  platform : Platform
}

///|
pub fn InputsCollector::new(platform~ : Platform = Posix) -> InputsCollector {
  { inputs: [], visited: Map([]), platform, }
}

///|
pub fn InputsCollector::visit_node(self : InputsCollector, node : Node) -> Unit {
  guard node.in_edge is Some(edge) else { return }
  for input in edge.inputs {
    if self.visited.contains(input.path) {
      continue
    }
    self.visited[input.path] = ()
    self.visit_node(input)
    match input.in_edge {
      Some(producer) if producer.is_phony() => ()
      _ => self.inputs.push(input)
    }
  }
}

///|
pub fn InputsCollector::inputs(self : InputsCollector) -> Array[Node] {
  self.inputs
}

///|
pub fn InputsCollector::inputs_as_strings(
  self : InputsCollector,
  escape~ : Bool = false,
) -> Array[String] {
  self.inputs.map(fn(input) {
    let path = input.path_decanonicalized(self.platform)
    if !escape {
      path
    } else {
      let out = StringBuilder()
      if self.platform is Windows {
        win32_escape(path, out)
      } else {
        shell_escape(path, out)
      }
      out.to_string()
    }
  })
}

///|
pub fn InputsCollector::reset(self : InputsCollector) -> Unit {
  self.inputs.clear()
  self.visited.clear()
}

///|
/// Collects the non-phony edges leading to nodes, dependencies first
/// (`ninja -t compdb-targets`).
pub struct CommandCollector {
  visited_nodes : Map[String, Unit]
  visited_edges : Map[Int32, Unit]
  in_edges : Array[Edge]
}

///|
pub fn CommandCollector::new() -> CommandCollector {
  { visited_nodes: Map([]), visited_edges: Map([]), in_edges: [], }
}

///|
pub fn CommandCollector::collect_from(
  self : CommandCollector,
  node : Node,
) -> Unit {
  if self.visited_nodes.contains(node.path) {
    return
  }
  self.visited_nodes[node.path] = ()
  guard node.in_edge is Some(edge) else { return }
  if self.visited_edges.contains(edge.id) {
    return
  }
  self.visited_edges[edge.id] = ()
  for input in edge.inputs {
    self.collect_from(input)
  }
  if !edge.is_phony() {
    self.in_edges.push(edge)
  }
}

///|
pub fn CommandCollector::in_edges(self : CommandCollector) -> Array[Edge] {
  self.in_edges
}

///|
/// Ready edges, highest critical path weight first and lowest id on ties
/// (ninja's `EdgePriorityQueue`).
pub struct EdgePriorityQueue {
  heap : Array[Edge]
}

///|
pub fn EdgePriorityQueue::new() -> EdgePriorityQueue {
  { heap: [], }
}

///|
/// Whether `a` should come out before `b`.
fn edge_before(a : Edge, b : Edge) -> Bool {
  if a.critical_path_weight != b.critical_path_weight {
    a.critical_path_weight > b.critical_path_weight
  } else {
    a.id < b.id
  }
}

///|
pub fn EdgePriorityQueue::length(self : EdgePriorityQueue) -> Int32 {
  self.heap.length()
}

///|
pub fn EdgePriorityQueue::is_empty(self : EdgePriorityQueue) -> Bool {
  self.heap.is_empty()
}

///|
pub fn EdgePriorityQueue::clear(self : EdgePriorityQueue) -> Unit {
  self.heap.clear()
}

///|
pub fn EdgePriorityQueue::push(self : EdgePriorityQueue, edge : Edge) -> Unit {
  let heap = self.heap
  heap.push(edge)
  let mut i = heap.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if !edge_before(heap[i], heap[parent]) {
      break
    }
    heap.swap(i, parent)
    i = parent
  }
}

///|
pub fn EdgePriorityQueue::top(self : EdgePriorityQueue) -> Edge? {
  self.heap.get(0)
}

///|
pub fn EdgePriorityQueue::pop(self : EdgePriorityQueue) -> Edge? {
  let heap = self.heap
  guard heap.length() > 0 else { return None }
  let top = heap[0]
  let last = heap.pop().unwrap()
  if heap.length() > 0 {
    heap[0] = last
    let mut i = 0
    while true {
      let left = 2 * i + 1
      let right = left + 1
      let mut best = i
      if left < heap.length() && edge_before(heap[left], heap[best]) {
        best = left
      }
      if right < heap.length() && edge_before(heap[right], heap[best]) {
        best = right
      }
      if best == i {
        break
      }
      heap.swap(i, best)
      i = best
    }
  }
  Some(top)
}
