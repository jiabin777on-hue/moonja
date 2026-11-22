// Port of ninja v1.13.2 src/jobserver.{h,cc} and the platform-independent
// part of src/jobserver-posix.cc (Apache-2.0, see NOTICE): a client of a
// GNU make jobserver pool.
// https://www.gnu.org/software/make/manual/html_node/Job-Slots.html

///|
/// A job slot (ninja's `Jobserver::Slot`): none, the one the parent
/// process implicitly gave us, or a byte read from the pool, which must be
/// written back as is.
#derive(Eq, Debug)
pub(all) enum JobSlot {
  NoSlot
  Implicit
  Explicit(Byte)
}

///|
pub fn JobSlot::is_valid(self : JobSlot) -> Bool {
  !(self is NoSlot)
}

///|
/// How a jobserver pool is reached (ninja's `Jobserver::Config::Mode`).
#derive(Eq, Debug)
pub(all) enum JobserverMode {
  NoMode
  /// `--jobserver-auth=R,W`: inherited descriptors. Recognized, not
  /// supported (ninja does not support it either).
  Pipe
  /// `--jobserver-auth=fifo:PATH` (GNU make 4.4 `--jobserver-style=fifo`).
  PosixFifo
  /// `--jobserver-auth=NAME`: a Win32 semaphore.
  Win32Semaphore
}

///|
#derive(Eq, Debug)
pub(all) struct JobserverConfig {
  mode : JobserverMode
  /// The FIFO path, or the semaphore name.
  path : String
}

///|
/// `R,W` as two integers; None if it is not that (sscanf "%d,%d").
fn parse_fd_pair(value : String) -> JobserverMode? {
  let parts = value.split(",").collect()
  guard parts.length() >= 2 else { return None }
  let read = scan_int(parts[0].to_owned())
  // sscanf stops at the first character that is not part of the number.
  let write = scan_int(parts[1:].map(fn(s) { s.to_owned() }).join(","))
  match (read, write) {
    (Some(r), Some(w)) => Some(if r < 0 || w < 0 { NoMode } else { Pipe })
    _ => None
  }
}

///|
/// The leading integer of `s` as sscanf's `%d` reads it: optional spaces,
/// a sign, then at least one digit.
fn scan_int(s : String) -> Int32? {
  let mut i = 0
  let n = s.length()
  while i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {
    i += 1
  }
  let mut negative = false
  if i < n && (s[i] == '-' || s[i] == '+') {
    negative = s[i] == '-'
    i += 1
  }
  let start = i
  let mut value = 0
  while i < n && s[i] >= '0' && s[i] <= '9' {
    value = value * 10 + (s[i].to_int() - 48)
    i += 1
  }
  if i == start {
    None
  } else if negative {
    Some(-value)
  } else {
    Some(value)
  }
}

///|
/// Reads the jobserver settings from a `MAKEFLAGS` value (ninja's
/// `Jobserver::ParseMakeFlagsValue`). The last setting wins.
pub fn parse_makeflags(makeflags : String) -> JobserverConfig raise NinjaError {
  let none = { mode: NoMode, path: "", }
  // Words are separated by single spaces or tabs; empty words are dropped.
  let args = []
  for word in makeflags.split(" ") {
    for arg in word.split("\t") {
      if arg != "" {
        args.push(arg.to_owned())
      }
    }
  }
  // A first word of flag letters holding `n` means `make -n`: do nothing.
  // GNU make starts MAKEFLAGS with a space when there are no letters, so a
  // first word starting with a dash is an option instead.
  if args.length() > 0 && !args[0].has_prefix("-") && args[0].contains("n") {
    return none
  }
  let mut config = none
  for arg in args {
    if arg.strip_prefix("--jobserver-auth=") is Some(value) {
      let value = value.to_owned()
      if parse_fd_pair(value) is Some(mode) {
        config = { mode, path: "", }
      } else if value.strip_prefix("fifo:") is Some(path) {
        config = { mode: PosixFifo, path: path.to_owned(), }
      } else {
        config = { mode: Win32Semaphore, path: value, }
      }
    } else if arg.strip_prefix("--jobserver-fds=") is Some(value) {
      // The pre-4.2 spelling of `--jobserver-auth=R,W`.
      let value = value.to_owned()
      guard parse_fd_pair(value) is Some(_) else {
        raise Error("Invalid file descriptor pair [\{value}]")
      }
      config = { mode: Pipe, path: "", }
    }
  }
  config
}

///|
/// `parse_makeflags`, rejecting what `platform` cannot use (ninja's
/// `Jobserver::ParseNativeMakeFlagsValue`).
pub fn parse_native_makeflags(
  makeflags : String,
  platform~ : Platform,
) -> JobserverConfig raise NinjaError {
  let config = parse_makeflags(makeflags)
  match (config.mode, platform) {
    (Pipe, _) => raise Error("Pipe-based protocol is not supported!")
    (PosixFifo, Windows) =>
      raise Error("FIFO mode is not supported on Windows!")
    (Win32Semaphore, Posix) =>
      raise Error("Semaphore mode is not supported on Posix!")
    _ => config
  }
}

///|
/// The token store behind a client: a FIFO opened without blocking.
pub(open) trait JobserverPool {
  /// Takes one byte, or None when the pool is empty.
  fn try_read(Self) -> Byte?
  /// Gives a byte back; errors are ignored, as ninja ignores them.
  fn write(Self, Byte) -> Unit
}

///|
/// A client of a jobserver pool (ninja's `PosixJobserverClient`).
struct JobserverClient {
  pool : &JobserverPool
  /// Whether the implicit slot is free.
  mut has_implicit_slot : Bool
}

///|
pub fn JobserverClient::new(pool : &JobserverPool) -> JobserverClient {
  { pool, has_implicit_slot: true, }
}

///|
/// A slot, or `NoSlot` if none is free. The implicit slot comes first,
/// without touching the pool.
pub fn JobserverClient::try_acquire(self : JobserverClient) -> JobSlot {
  if self.has_implicit_slot {
    self.has_implicit_slot = false
    return Implicit
  }
  match self.pool.try_read() {
    Some(byte) => Explicit(byte)
    None => NoSlot
  }
}

///|
/// Gives a slot back.
pub fn JobserverClient::release(self : JobserverClient, slot : JobSlot) -> Unit {
  match slot {
    NoSlot => ()
    Implicit => {
      if self.has_implicit_slot {
        abort("Implicit slot cannot be released twice!")
      }
      self.has_implicit_slot = true
    }
    Explicit(byte) => self.pool.write(byte)
  }
}

///|
/// Gives the slot `edge` holds back to the pool (ninja moves it out of the
/// edge), as a runner does for its commands when the build is aborted.
pub fn JobserverClient::release_edge(
  self : JobserverClient,
  edge : Edge,
) -> Unit {
  self.release(edge.job_slot)
  edge.job_slot = NoSlot
}

///|
/// A client for `config` (ninja's `Jobserver::Client::Create`).
/// `open_fifo` opens a FIFO pool without blocking; hosts without FIFOs
/// fail there.
pub fn create_jobserver_client(
  config : JobserverConfig,
  open_fifo~ : (String) -> Result[&JobserverPool, String],
) -> JobserverClient raise NinjaError {
  guard config.mode is PosixFifo else {
    raise Error("Unsupported jobserver mode")
  }
  if config.path == "" {
    raise Error("Empty fifo path")
  }
  match open_fifo(config.path) {
    Ok(pool) => JobserverClient::new(pool)
    Err(message) => raise Error(message)
  }
}
