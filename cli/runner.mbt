///|
/// Runs commands as real processes through the host (ninja's
/// `RealCommandRunner`). Results arrive later through `on_result`.
priv struct ProcessRunner {
  host : Host
  config : @moonja.BuildConfig
  active : Array[@moonja.Edge]
  mut aborted : Bool
  mut on_result : (@moonja.CommandResult) -> Unit
}

///|
fn ProcessRunner::new(
  host : Host,
  config : @moonja.BuildConfig,
) -> ProcessRunner {
  { host, config, active: [], aborted: false, on_result: fn(_) {  }, }
}

///|
impl @moonja.CommandRunner for ProcessRunner with fn can_run_more(self) {
  let mut capacity = self.config.parallelism.to_int64() -
    self.active.length().to_int64()
  if self.config.max_load_average > 0.0 {
    // Truncated toward zero, like ninja's int conversion.
    let load_capacity = (self.config.max_load_average -
    (self.host.load_average)()).to_int64()
    if load_capacity < capacity {
      capacity = load_capacity
    }
  }
  if capacity < 0 {
    capacity = 0
  }
  if capacity == 0 && self.active.is_empty() {
    // Always make progress.
    capacity = 1
  }
  if capacity > int_max.to_int64() {
    int_max
  } else {
    capacity.to_int()
  }
}

///|
impl @moonja.CommandRunner for ProcessRunner with fn start_command(self, edge) {
  let command = edge.evaluate_command() catch { _ => return false }
  self.active.push(edge)
  let error = self.host.processes.spawn(command, edge.use_console(), fn(
    code,
    output,
  ) {
    let index = self.active.search_by(fn(e) { physical_equal(e, edge) })
    if index is Some(i) {
      ignore(self.active.remove(i))
    }
    if !self.aborted {
      (self.on_result)(
        @moonja.CommandResult::new(
          edge,
          @moonja.ExitStatus::from_code(code),
          output~,
        ),
      )
    }
  })
  if error is Some(message) {
    ignore(self.active.pop())
    self.host.fatal_no_raise("posix_spawn: \{message}")
    return false
  }
  true
}

///|
impl @moonja.CommandRunner for ProcessRunner with fn active_edges(self) {
  self.active.copy()
}

///|
impl @moonja.CommandRunner for ProcessRunner with fn abort(self) {
  self.aborted = true
  self.host.processes.kill_all()
  self.active.clear()
}

///|
/// Pretends every command succeeded (ninja's `DryRunCommandRunner`).
priv struct DryRunRunner {
  finished : Array[@moonja.Edge]
  mut next : Int32
}

///|
impl @moonja.CommandRunner for DryRunRunner with fn can_run_more(_self) {
  int_max
}

///|
impl @moonja.CommandRunner for DryRunRunner with fn start_command(self, edge) {
  self.finished.push(edge)
  true
}

///|
impl @moonja.CommandRunner for DryRunRunner with fn active_edges(_self) {
  []
}

///|
impl @moonja.CommandRunner for DryRunRunner with fn abort(self) {
  self.next = self.finished.length()
}

///|
impl @moonja.WaitingCommandRunner for DryRunRunner with fn wait_for_command(
  self,
) {
  guard self.next < self.finished.length() else { return None }
  let edge = self.finished[self.next]
  self.next += 1
  Some(@moonja.CommandResult::new(edge, Success))
}
