///|
/// How a build or a command ended (ninja's `ExitStatus`).
#derive(Eq, Debug)
pub(all) enum ExitStatus {
  /// Exit code 0.
  Success
  /// Exit code 1.
  Failure
  /// Exit code 130: the user interrupted the build, or a command died of
  /// SIGINT, SIGTERM or SIGHUP.
  Interrupted
  /// Any other exit code, propagated from a failing command.
  Exited(Int32)
}

///|
/// The status for a process exit code. ninja's `ExitStatus` is the exit
/// code itself, so a command exiting with 127 makes ninja exit with 127.
pub fn ExitStatus::from_code(code : Int32) -> ExitStatus {
  match code {
    0 => Success
    1 => Failure
    130 => Interrupted
    _ => Exited(code)
  }
}

///|
/// The process exit code for the status.
pub fn ExitStatus::code(self : ExitStatus) -> Int32 {
  match self {
    Success => 0
    Failure => 1
    Interrupted => 130
    Exited(code) => code
  }
}

///|
/// Progress reporting (ninja's `Status`).
pub(open) trait Status {
  fn edge_added_to_plan(Self, Edge) -> Unit
  fn edge_removed_from_plan(Self, Edge) -> Unit
  fn build_edge_started(Self, Edge, Int64) -> Unit
  fn build_edge_finished(Self, Edge, Int64, Int64, ExitStatus, String) -> Unit
  fn build_started(Self) -> Unit
  fn build_finished(Self) -> Unit
  fn info(Self, String) -> Unit
  fn warning(Self, String) -> Unit
  fn error(Self, String) -> Unit
}

///|
/// A `Status` that reports nothing.
pub struct NullStatus {}

///|
pub fn NullStatus::new() -> NullStatus {
  NullStatus::{ }
}

///|
pub impl Status for NullStatus with fn edge_added_to_plan(_, _) {
  ()
}

///|
pub impl Status for NullStatus with fn edge_removed_from_plan(_, _) {
  ()
}

///|
pub impl Status for NullStatus with fn build_edge_started(_, _, _) {
  ()
}

///|
pub impl Status for NullStatus with fn build_edge_finished(_, _, _, _, _, _) {
  ()
}

///|
pub impl Status for NullStatus with fn build_started(_) {
  ()
}

///|
pub impl Status for NullStatus with fn build_finished(_) {
  ()
}

///|
pub impl Status for NullStatus with fn info(_, _) {
  ()
}

///|
pub impl Status for NullStatus with fn warning(_, _) {
  ()
}

///|
pub impl Status for NullStatus with fn error(_, _) {
  ()
}

///|
/// The outcome of one command.
pub struct CommandResult {
  edge : Edge
  mut status : ExitStatus
  mut output : String
}

///|
pub fn CommandResult::new(
  edge : Edge,
  status : ExitStatus,
  output~ : String = "",
) -> CommandResult {
  { edge, status, output, }
}

///|
pub fn CommandResult::edge(self : CommandResult) -> Edge {
  self.edge
}

///|
pub fn CommandResult::status(self : CommandResult) -> ExitStatus {
  self.status
}

///|
pub fn CommandResult::output(self : CommandResult) -> String {
  self.output
}

///|
/// Runs commands (ninja's `CommandRunner`). Hosts implement it with real
/// processes; tests with a fake. Waiting for a command is not part of the
/// trait: a synchronous host calls `Builder::build`, an event loop feeds
/// results to `Builder::command_finished`.
pub(open) trait CommandRunner {
  /// How many more commands may start now.
  fn can_run_more(Self) -> Int32
  /// Starts the edge's command; false if it could not be started.
  fn start_command(Self, Edge) -> Bool
  /// The edges whose commands are running.
  fn active_edges(Self) -> Array[Edge]
  /// Stops all running commands.
  fn abort(Self) -> Unit
}

///|
/// A runner that can also block until some command finishes; None when
/// there is nothing to wait for or the user interrupted the build.
pub(open) trait WaitingCommandRunner: CommandRunner {
  fn wait_for_command(Self) -> CommandResult?
}

///|
#derive(Eq, Debug)
pub(all) enum Verbosity {
  /// No output, for tests.
  Quiet
  /// Command output, but no status line.
  NoStatusUpdate
  Normal
  Verbose
}

///|
pub(all) struct BuildConfig {
  mut verbosity : Verbosity
  mut dry_run : Bool
  mut parallelism : Int32
  mut failures_allowed : Int32
  /// No new commands start above this load; <= 0 disables the limit.
  mut max_load_average : Double
  /// `-d keepdepfile`.
  mut keep_depfile : Bool
  /// `-d keeprsp`.
  mut keep_rsp : Bool
  /// `-d explain`.
  mut explain : Bool
}

///|
pub fn BuildConfig::default() -> BuildConfig {
  {
    verbosity: Normal,
    dry_run: false,
    parallelism: 1,
    failures_allowed: 1,
    max_load_average: -0.0,
    keep_depfile: false,
    keep_rsp: false,
    explain: false,
  }
}

///|
#derive(Eq, Debug)
enum Want {
  /// Not built itself, but its dependents may be.
  WantNothing
  /// Will be built once its inputs are ready.
  WantToStart
  /// Scheduled; waiting for it to finish.
  WantToFinish
}

///|
struct Wanted {
  edge : Edge
  mut want : Want
}

///|
/// What to build and in which order (ninja's `Plan`).
pub struct Plan {
  /// Edges reached from the targets, by edge id.
  want : Map[Int32, Wanted]
  ready : EdgePriorityQueue
  targets : Array[Node]
  /// Edges we want to build, including phony ones.
  mut wanted_edges : Int32
  /// Edges with a command we want to build.
  mut command_edges : Int32
  mut status : &Status
  /// Loads a dyndep file that just became ready (the builder's job).
  mut dyndep_loader : ((Node) -> Unit raise NinjaError)?
}

///|
pub fn Plan::new() -> Plan {
  {
    want: Map([]),
    ready: EdgePriorityQueue::new(),
    targets: [],
    wanted_edges: 0,
    command_edges: 0,
    status: NullStatus::new(),
    dyndep_loader: None,
  }
}

///|
pub fn Plan::more_to_do(self : Plan) -> Bool {
  self.wanted_edges > 0 && self.command_edges > 0
}

///|
pub fn Plan::command_edge_count(self : Plan) -> Int32 {
  self.command_edges
}

///|
pub fn Plan::reset(self : Plan) -> Unit {
  self.command_edges = 0
  self.wanted_edges = 0
  self.ready.clear()
  self.want.clear()
}

///|
/// The wanted edges in ninja's map order (by edge, here by id).
fn Plan::wanted_in_order(self : Plan) -> Array[Wanted] {
  let all = self.want.values().collect()
  all.sort_by(fn(a, b) { a.edge.id.compare(b.edge.id) })
  all
}

///|
/// Adds `target` and what it needs to the plan. Fails if a needed source
/// file is missing.
pub fn Plan::add_target(self : Plan, target : Node) -> Unit raise NinjaError {
  self.targets.push(target)
  ignore(self.add_sub_target(target, None, None))
}

///|
fn Plan::add_sub_target(
  self : Plan,
  node : Node,
  dependent : Node?,
  dyndep_walk : Map[Int32, Edge]?,
) -> Bool raise NinjaError {
  guard node.in_edge is Some(edge) else {
    // A leaf: a source file from the manifest, or an implicit input from a
    // depfile or dyndep file. A dirty source file is missing.
    if node.dirty && !node.generated_by_dep_loader {
      let referenced = match dependent {
        Some(d) => ", needed by '\{d.path}',"
        None => ""
      }
      raise Error(
        "'\{node.path}'\{referenced} missing and no known rule to make it",
      )
    }
    return false
  }
  if edge.outputs_ready {
    return false
  }
  let is_new = !self.want.contains(edge.id)
  if is_new {
    self.want[edge.id] = { edge, want: WantNothing, }
  }
  let wanted = self.want[edge.id]
  if dyndep_walk is Some(_) && wanted.want is WantToFinish {
    // Already scheduled.
    return false
  }
  if node.dirty && wanted.want is WantNothing {
    wanted.want = WantToStart
    self.edge_wanted(edge)
  }
  if dyndep_walk is Some(walk) {
    walk[edge.id] = edge
  }
  if !is_new {
    // The inputs were visited already.
    return true
  }
  for input in edge.inputs {
    ignore(self.add_sub_target(input, Some(node), dyndep_walk))
  }
  true
}

///|
fn Plan::edge_wanted(self : Plan, edge : Edge) -> Unit {
  self.wanted_edges += 1
  if !edge.is_phony() {
    self.command_edges += 1
    self.status.edge_added_to_plan(edge)
  }
}

///|
/// The next edge to run, if one is ready.
pub fn Plan::find_work(self : Plan) -> Edge? {
  self.ready.pop()
}

///|
fn Plan::schedule_work(self : Plan, wanted : Wanted) -> Unit {
  if wanted.want is WantToFinish {
    // Already scheduled: an edge and one of its dependencies share an
    // order-only input, or a node lists an out edge twice.
    return
  }
  wanted.want = WantToFinish
  let edge = wanted.edge
  let pool = edge.pool
  if pool.should_delay_edge() {
    pool.delay_edge(edge)
    pool.retrieve_ready_edges(self.ready)
  } else {
    pool.edge_scheduled(edge)
    self.ready.push(edge)
  }
}

///|
#derive(Eq, Debug)
pub(all) enum EdgeResult {
  EdgeFailed
  EdgeSucceeded
}

///|
/// Marks `edge` as finished and schedules what that makes ready.
pub fn Plan::edge_finished(
  self : Plan,
  edge : Edge,
  result : EdgeResult,
) -> Unit raise NinjaError {
  guard self.want.get(edge.id) is Some(wanted) else {
    abort("edge_finished: edge not in plan")
  }
  let directly_wanted = !(wanted.want is WantNothing)
  // This may free up delayed edges of the pool.
  if directly_wanted {
    edge.pool.edge_finished(edge)
  }
  edge.pool.retrieve_ready_edges(self.ready)
  if result is EdgeFailed {
    return
  }
  if directly_wanted {
    self.wanted_edges -= 1
  }
  self.want.remove(edge.id)
  edge.outputs_ready = true
  for out in edge.outputs {
    self.node_finished(out)
  }
}

///|
fn Plan::node_finished(self : Plan, node : Node) -> Unit raise NinjaError {
  // A dyndep file that is now ready gets loaded, which updates the plan.
  if node.dyndep_pending {
    guard self.dyndep_loader is Some(load) else {
      abort("dyndep requires a builder")
    }
    load(node)
    return
  }
  for edge in node.out_edges {
    if self.want.get(edge.id) is Some(wanted) {
      self.edge_maybe_ready(wanted)
    }
  }
}

///|
fn Plan::edge_maybe_ready(
  self : Plan,
  wanted : Wanted,
) -> Unit raise NinjaError {
  if wanted.edge.all_inputs_ready() {
    if !(wanted.want is WantNothing) {
      self.schedule_work(wanted)
    } else {
      // Not wanted itself, but maybe one of its dependents is.
      self.edge_finished(wanted.edge, EdgeSucceeded)
    }
  }
}

///|
/// Marks `node` clean after a restat rule left it unchanged, and drops the
/// edges that no longer need to run.
pub fn Plan::clean_node(
  self : Plan,
  scan : DependencyScan,
  node : Node,
) -> Unit raise NinjaError {
  node.dirty = false
  for edge in node.out_edges {
    guard self.want.get(edge.id) is Some(wanted) else { continue }
    if wanted.want is WantNothing {
      continue
    }
    // Leave edges whose deps failed to load alone.
    if edge.deps_missing {
      continue
    }
    let end = edge.inputs.length() - edge.order_only_deps
    let mut all_clean = true
    for i in 0..<end {
      if edge.inputs[i].dirty {
        all_clean = false
        break
      }
    }
    if !all_clean {
      continue
    }
    let mut most_recent_input : Node? = None
    for i in 0..<end {
      let input = edge.inputs[i]
      match most_recent_input {
        Some(newest) if input.mtime <= newest.mtime => ()
        _ => most_recent_input = Some(input)
      }
    }
    // The edge is dirty if any output still is.
    if !scan.recompute_outputs_dirty(edge, most_recent_input) {
      for out in edge.outputs {
        self.clean_node(scan, out)
      }
      wanted.want = WantNothing
      self.wanted_edges -= 1
      if !edge.is_phony() {
        self.command_edges -= 1
        self.status.edge_removed_from_plan(edge)
      }
    }
  }
}

///|
/// Updates the plan after the dyndep file `node` was loaded into `file`.
pub fn Plan::dyndeps_loaded(
  self : Plan,
  scan : DependencyScan,
  node : Node,
  file : DyndepFile,
) -> Unit raise NinjaError {
  // Dependents may be dirty now.
  self.refresh_dyndep_dependents(scan, node)
  // Walk the newly reachable part of the graph from the edges in the plan
  // that the file has information for.
  let entries = file.entries.values().collect()
  entries.sort_by(fn(a, b) { a.edge.id.compare(b.edge.id) })
  let roots = entries.filter(fn(d) {
    !d.edge.outputs_ready && self.want.contains(d.edge.id)
  })
  let walk : Map[Int32, Edge] = Map([])
  for root in roots {
    for input in root.implicit_inputs {
      ignore(self.add_sub_target(input, Some(root.edge.outputs[0]), Some(walk)))
    }
  }
  // Also the out edges of the dyndep file that are in the plan, as
  // node_finished would have handled them.
  for edge in node.out_edges {
    if self.want.contains(edge.id) {
      walk[edge.id] = edge
    }
  }
  let walked = walk.values().collect()
  walked.sort_by(fn(a, b) { a.id.compare(b.id) })
  for edge in walked {
    if self.want.get(edge.id) is Some(wanted) {
      self.edge_maybe_ready(wanted)
    }
  }
}

///|
fn Plan::refresh_dyndep_dependents(
  self : Plan,
  scan : DependencyScan,
  node : Node,
) -> Unit raise NinjaError {
  // Unmark the transitive dependents so the scan visits them again.
  let dependents : Map[Int32, Node] = Map([])
  self.unmark_dependents(node, dependents)
  let ordered = dependents.values().collect()
  ordered.sort_by(fn(a, b) { a.index.compare(b.index) })
  for n in ordered {
    // Is the dependent dirty now? This also finds new cycles.
    let validation_nodes = []
    scan.recompute_dirty(n, validation_nodes~)
    // New validations become top-level targets.
    for v in validation_nodes {
      if v.in_edge is Some(e) && !e.outputs_ready {
        self.add_target(v)
      }
    }
    if !n.dirty {
      continue
    }
    // The edge was seen before but maybe not wanted; with the dyndep
    // information an output is known to be dirty, so it is wanted now.
    guard n.in_edge is Some(edge) && self.want.get(edge.id) is Some(wanted) else {
      abort("dyndep dependent without a planned edge")
    }
    if wanted.want is WantNothing {
      wanted.want = WantToStart
      self.edge_wanted(edge)
    }
  }
}

///|
fn Plan::unmark_dependents(
  self : Plan,
  node : Node,
  dependents : Map[Int32, Node],
) -> Unit {
  for edge in node.out_edges {
    if !self.want.contains(edge.id) {
      continue
    }
    if !(edge.mark is VisitNone) {
      edge.mark = VisitNone
      for out in edge.outputs {
        if !dependents.contains(out.index) {
          dependents[out.index] = out
          self.unmark_dependents(out, dependents)
        }
      }
    }
  }
}

///|
/// Phony edges cost nothing; every other edge costs 1.
fn edge_weight_heuristic(edge : Edge) -> Int64 {
  if edge.is_phony() {
    0
  } else {
    1
  }
}

///|
/// Weighs each edge by the longest chain of work that depends on it, so
/// the scheduler starts the critical path first.
fn Plan::compute_critical_path(self : Plan) -> Unit {
  // Topological order of the edges reachable from the targets: every edge
  // after the edges producing its inputs.
  let sorted : Array[Edge] = []
  let visited : Map[Int32, Unit] = Map([])
  fn visit(edge : Edge) -> Unit {
    if visited.contains(edge.id) {
      return
    }
    visited[edge.id] = ()
    for input in edge.inputs {
      if input.in_edge is Some(producer) {
        visit(producer)
      }
    }
    sorted.push(edge)
  }

  for target in self.targets {
    if target.in_edge is Some(producer) {
      visit(producer)
    }
  }
  for edge in sorted {
    edge.critical_path_weight = edge_weight_heuristic(edge)
  }
  // Propagate weights from dependents to their producers.
  for i = sorted.length() - 1; i >= 0; i = i - 1 {
    let edge = sorted[i]
    for input in edge.inputs {
      guard input.in_edge is Some(producer) else { continue }
      let candidate = edge.critical_path_weight +
        edge_weight_heuristic(producer)
      if candidate > producer.critical_path_weight {
        producer.critical_path_weight = candidate
      }
    }
  }
}

///|
fn Plan::schedule_initial_edges(self : Plan) -> Unit {
  let pools : Array[Pool] = []
  for wanted in self.wanted_in_order() {
    let edge = wanted.edge
    if wanted.want is WantToStart && edge.all_inputs_ready() {
      let pool = edge.pool
      if pool.should_delay_edge() {
        pool.delay_edge(edge)
        if !pools.iter().any(fn(p) { physical_equal(p, pool) }) {
          pools.push(pool)
        }
      } else {
        self.schedule_work(wanted)
      }
    }
  }
  // Retrieve once at the end, so that the highest-priority edges of each
  // pool go first, not the first ones in the map.
  pools.sort_by(fn(a, b) { compare_lexical(a.name, b.name) })
  for pool in pools {
    pool.retrieve_ready_edges(self.ready)
  }
}

///|
/// Computes priorities and queues the edges that can start.
pub fn Plan::prepare_queue(self : Plan) -> Unit {
  self.compute_critical_path()
  self.schedule_initial_edges()
}

///|
/// A step of a build driven by the host.
#derive(Eq, Debug)
pub(all) enum BuildProgress {
  /// Some commands are running; report one with `command_finished`.
  Waiting
  /// The build is over, with an error message unless it succeeded.
  Finished(ExitStatus, String)
}

///|
/// Runs a plan: starts commands, records their results and updates the
/// graph (ninja's `Builder`).
pub struct Builder {
  state : State
  config : BuildConfig
  plan : Plan
  status : &Status
  disk : &Disk
  scan : DependencyScan
  explanations : Explanations?
  lock_file_path : String
  start_time_millis : Int64
  /// The working directory, for `deps = msvc` on Windows.
  cwd : String
  /// Milliseconds on any fixed clock.
  clock : () -> Int64
  /// Start times of running edges, relative to the build start, by id.
  running_edges : Map[Int32, Int64]
  mut exit_code : ExitStatus
  mut pending_commands : Int32
  mut failures_allowed : Int32
}

///|
pub fn Builder::new(
  state : State,
  config : BuildConfig,
  disk : &Disk,
  status~ : &Status = NullStatus::new(),
  build_log? : BuildLog,
  deps_log? : DepsLog,
  start_time_millis~ : Int64 = 0,
  clock~ : () -> Int64 = fn() { 0 },
  cwd~ : String = "C:\\",
) -> Builder {
  let explanations = if config.explain {
    Some(Explanations::new())
  } else {
    None
  }
  let build_dir = state.bindings.lookup("builddir")
  let lock_file_path = if build_dir == "" {
    ".ninja_lock"
  } else {
    build_dir + "/.ninja_lock"
  }
  let plan = Plan::new()
  plan.status = status
  let builder : Builder = {
    state,
    config,
    plan,
    status,
    disk,
    scan: DependencyScan::new(state, disk, build_log?, deps_log?, explanations?),
    explanations,
    lock_file_path,
    start_time_millis,
    cwd,
    clock,
    running_edges: Map([]),
    exit_code: Success,
    pending_commands: 0,
    failures_allowed: config.failures_allowed,
  }
  plan.dyndep_loader = Some(fn(node) raise NinjaError {
    builder.load_dyndeps(node)
  })
  builder
}

///|
pub fn Builder::plan(self : Builder) -> Plan {
  self.plan
}

///|
pub fn Builder::scan(self : Builder) -> DependencyScan {
  self.scan
}

///|
pub fn Builder::explanations(self : Builder) -> Explanations? {
  self.explanations
}

///|
pub fn Builder::exit_code(self : Builder) -> ExitStatus {
  self.exit_code
}

///|
pub fn Builder::set_build_log(self : Builder, log : BuildLog?) -> Unit {
  self.scan.set_build_log(log)
}

///|
/// Adds the target named `name`.
pub fn Builder::add_target_name(
  self : Builder,
  name : String,
) -> Node raise NinjaError {
  guard self.state.lookup_node(name) is Some(node) else {
    raise Error("unknown target: '\{name}'")
  }
  self.add_target(node)
  node
}

///|
/// Scans `target` and adds what it needs, and its validations, to the plan.
pub fn Builder::add_target(
  self : Builder,
  target : Node,
) -> Unit raise NinjaError {
  let validation_nodes = []
  self.scan.recompute_dirty(target, validation_nodes~)
  match target.in_edge {
    Some(edge) if edge.outputs_ready => ()
    _ => self.plan.add_target(target)
  }
  // Validations become top-level targets too.
  for v in validation_nodes {
    if v.in_edge is Some(edge) && !edge.outputs_ready {
      self.plan.add_target(v)
    }
  }
}

///|
pub fn Builder::already_up_to_date(self : Builder) -> Bool {
  !self.plan.more_to_do()
}

///|
fn Builder::set_failure_code(self : Builder, code : ExitStatus) -> Unit {
  // Success never overwrites an error.
  if !(code is Success) {
    self.exit_code = code
  }
}

///|
/// Runs the whole build with a runner that can wait for commands.
pub fn[R : WaitingCommandRunner] Builder::build(
  self : Builder,
  runner : R,
) -> (ExitStatus, String) {
  let mut progress = self.start_build(runner)
  while true {
    match progress {
      Finished(status, message) => return (status, message)
      Waiting =>
        progress = self.command_finished(runner, runner.wait_for_command())
    }
  }
  abort("unreachable")
}

///|
/// Begins the build: queues the ready edges and starts as many commands as
/// the runner allows.
pub fn[R : CommandRunner] Builder::start_build(
  self : Builder,
  runner : R,
) -> BuildProgress {
  self.plan.prepare_queue()
  self.pending_commands = 0
  self.failures_allowed = self.config.failures_allowed
  self.status.build_started()
  self.advance(runner)
}

///|
fn[R : CommandRunner] Builder::fail(
  self : Builder,
  runner : R,
  status : ExitStatus,
  message : String,
) -> BuildProgress {
  self.cleanup(runner)
  self.status.build_finished()
  Finished(status, message)
}

///|
/// Starts commands until the runner is full; then either waits for one or
/// ends the build.
fn[R : CommandRunner] Builder::advance(
  self : Builder,
  runner : R,
) -> BuildProgress {
  while self.plan.more_to_do() {
    if self.failures_allowed > 0 {
      let mut capacity = runner.can_run_more()
      while capacity > 0 {
        guard self.plan.find_work() is Some(edge) else { break }
        let failure : String? = try {
          if edge.get_binding_bool("generator") &&
            self.scan.build_log is Some(log) {
            log.close(self.disk)
          }
          self.start_edge(runner, edge)
          if edge.is_phony() {
            self.plan.edge_finished(edge, EdgeSucceeded)
          }
          None
        } catch {
          error => Some(error.message())
        }
        if failure is Some(message) {
          return self.fail(runner, Failure, message)
        }
        if !edge.is_phony() {
          self.pending_commands += 1
          capacity -= 1
          let current = runner.can_run_more()
          if current < capacity {
            capacity = current
          }
        }
      }
      // No work left and nothing running: the loop is over.
      if self.pending_commands == 0 && !self.plan.more_to_do() {
        break
      }
    }
    if self.pending_commands > 0 {
      return Waiting
    }
    // No progress is possible.
    self.status.build_finished()
    let message = if self.failures_allowed == 0 {
      if self.config.failures_allowed > 1 {
        "subcommands failed"
      } else {
        "subcommand failed"
      }
    } else if self.failures_allowed < self.config.failures_allowed {
      "cannot make progress due to previous errors"
    } else {
      "stuck [this is a bug]"
    }
    return Finished(self.exit_code, message)
  }
  self.status.build_finished()
  Finished(Success, "")
}

///|
/// Reports the result of a running command (None: interrupted) and goes on
/// with the build.
pub fn[R : CommandRunner] Builder::command_finished(
  self : Builder,
  runner : R,
  result : CommandResult?,
) -> BuildProgress {
  guard result is Some(result) && !(result.status is Interrupted) else {
    let status = match result {
      Some(r) => r.status
      None => Failure
    }
    return self.fail(runner, status, "interrupted by user")
  }
  self.pending_commands -= 1
  let error = try {
    self.finish_command(result)
    None
  } catch {
    e => Some(e.message())
  }
  self.set_failure_code(result.status)
  if error is Some(message) {
    if result.status is Success {
      // The command "succeeded" but finishing it failed.
      result.status = Failure
      self.set_failure_code(Failure)
    }
    return self.fail(runner, result.status, message)
  }
  if !(result.status is Success) && self.failures_allowed > 0 {
    self.failures_allowed -= 1
  }
  self.advance(runner)
}

///|
/// The directory part of `path`, without trailing separators.
fn dir_name(path : String, platform : Platform) -> String {
  let mut slash = path.length() - 1
  while slash >= 0 && !platform.is_separator(path.unsafe_get(slash)) {
    slash -= 1
  }
  if slash < 0 {
    return ""
  }
  while slash > 0 && platform.is_separator(path.unsafe_get(slash - 1)) {
    slash -= 1
  }
  path.unsafe_substring(start=0, end=slash)
}

///|
/// Creates the directories leading to `path` (ninja's `MakeDirs`).
pub fn make_dirs(
  disk : &Disk,
  path : String,
  platform~ : Platform = Posix,
) -> Bool raise NinjaError {
  let dir = dir_name(path, platform)
  if dir == "" {
    // The root; assume it is there.
    return true
  }
  if disk.stat(dir) > 0 {
    return true
  }
  // Create the parent first.
  if !make_dirs(disk, dir, platform~) {
    return false
  }
  disk.make_dir(dir)
}

///|
fn[R : CommandRunner] Builder::start_edge(
  self : Builder,
  runner : R,
  edge : Edge,
) -> Unit raise NinjaError {
  if edge.is_phony() {
    return
  }
  let start = (self.clock)() - self.start_time_millis
  self.running_edges[edge.id] = start
  self.status.build_edge_started(edge, start)
  let mut build_start : Int64 = if self.config.dry_run { 0 } else { -1 }
  // Create the output directories, and note the file system's current time
  // to record later.
  for out in edge.outputs {
    if !make_dirs(self.disk, out.path, platform=self.state.platform) {
      raise Error("")
    }
    if build_start == -1 {
      ignore(self.disk.write_file(self.lock_file_path, ""))
      build_start = self.disk.stat(self.lock_file_path) catch { _ => 0 }
      if build_start == -1 {
        build_start = 0
      }
    }
  }
  edge.command_start_time = build_start
  let depfile = edge.get_unescaped_depfile()
  if depfile != "" &&
    !make_dirs(self.disk, depfile, platform=self.state.platform) {
    raise Error("")
  }
  let rspfile = edge.get_unescaped_rspfile()
  if rspfile != "" {
    let content = edge.get_binding("rspfile_content")
    if !self.disk.write_file(rspfile, content) {
      raise Error("")
    }
  }
  if !runner.start_command(edge) {
    raise Error("command '\{edge.evaluate_command()}' failed.")
  }
}

///|
fn Builder::finish_command(
  self : Builder,
  result : CommandResult,
) -> Unit raise NinjaError {
  let edge = result.edge
  // Extract dependencies first: it filters the output (MSVC's
  // /showIncludes, even on failure), and its failure fails the command.
  let deps_type = edge.get_binding("deps")
  let deps_prefix = edge.get_binding("msvc_deps_prefix")
  let mut deps_nodes : Array[Node] = []
  if deps_type != "" {
    match self.extract_deps(result, deps_type, deps_prefix) {
      Ok(nodes) => deps_nodes = nodes
      Err(message) =>
        if result.status is Success {
          if result.output != "" {
            result.output = result.output + "\n"
          }
          result.output = result.output + message
          result.status = Failure
        }
    }
  }
  let start = self.running_edges.get(edge.id).unwrap_or(0)
  let end = (self.clock)() - self.start_time_millis
  self.running_edges.remove(edge.id)
  self.status.build_edge_finished(
    edge,
    start,
    end,
    result.status,
    result.output,
  )
  if !(result.status is Success) {
    self.plan.edge_finished(edge, EdgeFailed)
    return
  }
  // Restat the outputs.
  let mut record_mtime : Int64 = 0
  if !self.config.dry_run {
    let restat = edge.get_binding_bool("restat")
    let generator = edge.get_binding_bool("generator")
    let mut node_cleaned = false
    record_mtime = edge.command_start_time
    // Restat and generator rules record the outputs' mtimes; so does an
    // edge whose start time could not be determined.
    if record_mtime == 0 || restat || generator {
      for out in edge.outputs {
        let new_mtime = self.disk.stat(out.path)
        if new_mtime > record_mtime {
          record_mtime = new_mtime
        }
        if out.mtime == new_mtime && restat {
          // The command left the output alone (or it does not exist):
          // propagate the clean state.
          self.plan.clean_node(self.scan, out)
          node_cleaned = true
        }
      }
    }
    if node_cleaned {
      record_mtime = edge.command_start_time
    }
  }
  self.plan.edge_finished(edge, EdgeSucceeded)
  // Delete the response file.
  let rspfile = edge.get_unescaped_rspfile()
  if rspfile != "" && !self.config.keep_rsp {
    ignore(self.disk.remove_file(rspfile))
  }
  if self.scan.build_log is Some(log) {
    log.record_command(
      self.disk,
      edge,
      start.to_int(),
      end.to_int(),
      mtime=record_mtime,
    )
  }
  if deps_type != "" && !self.config.dry_run {
    guard self.scan.deps_log() is Some(deps_log) else { return }
    for out in edge.outputs {
      let deps_mtime = self.disk.stat(out.path)
      deps_log.record_deps(self.disk, out, deps_mtime, deps_nodes)
    }
  }
}

///|
fn Builder::extract_deps(
  self : Builder,
  result : CommandResult,
  deps_type : String,
  deps_prefix : String,
) -> Result[Array[Node], String] raise NinjaError {
  match deps_type {
    "msvc" => {
      let normalizer = if self.state.platform is Windows {
        Some(IncludesNormalize::new(".", self.cwd))
      } else {
        None
      }
      let parsed = parse_cl_output(result.output, deps_prefix, normalizer?) catch {
        Fatal(_) as error => raise error
        error => return Err(error.message())
      }
      result.output = parsed.filtered
      // All backslashes: some of them certainly are, and MSVC paths do not
      // reach command lines.
      Ok(
        parsed.includes.map(fn(path) { self.state.get_node(path, 0xffffffff) }),
      )
    }
    "gcc" => {
      let depfile = result.edge.get_unescaped_depfile()
      if depfile == "" {
        return Err("edge with deps=gcc but no depfile makes no sense")
      }
      // A missing depfile reads as empty.
      let content = self.disk.read_file(depfile) catch {
        error => return Err(error.message())
      }
      let content = content.unwrap_or("")
      if content == "" {
        return Ok([])
      }
      let deps = parse_depfile(content) catch {
        error => return Err(error.message())
      }
      let nodes = deps.ins.map(fn(input) {
        let (path, slash_bits) = canonicalize_path(
          input,
          platform=self.state.platform,
        )
        self.state.get_node(path, slash_bits)
      })
      if !self.config.keep_depfile && self.disk.remove_file(depfile) < 0 {
        return Err("deleting depfile: cannot remove \{depfile}\n")
      }
      Ok(nodes)
    }
    _ => raise Fatal("unknown deps type '\{deps_type}'")
  }
}

///|
/// Loads a dyndep file that just became ready and updates the plan.
pub fn Builder::load_dyndeps(
  self : Builder,
  node : Node,
) -> Unit raise NinjaError {
  let file = DyndepFile::new()
  self.scan.load_dyndeps(node, file~)
  self.plan.dyndeps_loaded(self.scan, node, file)
}

///|
/// Stops the running commands and removes their possibly half-written
/// outputs, and the lock file.
pub fn[R : CommandRunner] Builder::cleanup(self : Builder, runner : R) -> Unit {
  let active = runner.active_edges()
  runner.abort()
  for edge in active {
    let depfile = edge.get_unescaped_depfile() catch { _ => "" }
    for out in edge.outputs {
      // Remove an output only if it changed, except with a depfile: the
      // command may have touched the depfile and not the output.
      let new_mtime = self.disk.stat(out.path) catch {
        error => {
          self.status.error(error.message())
          -1
        }
      }
      if depfile != "" || out.mtime != new_mtime {
        ignore(self.disk.remove_file(out.path))
      }
    }
    if depfile != "" {
      ignore(self.disk.remove_file(depfile))
    }
  }
  let lock = self.disk.stat(self.lock_file_path) catch { _ => 0 }
  if lock > 0 {
    ignore(self.disk.remove_file(self.lock_file_path))
  }
}
