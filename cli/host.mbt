///|
/// Runs shell commands for the build. A host implements it with real
/// processes; tests with a fake.
pub(open) trait Processes {
  /// Starts `command` (through `/bin/sh -c` on POSIX, as a CreateProcess
  /// command line on Windows). A console command shares the terminal;
  /// otherwise stdin is empty and stdout and stderr are captured together.
  /// `on_exit(code, output)` is called once the command ends, from the
  /// event loop and never from inside `spawn`. Returns an error message if
  /// the command could not be started at all.
  fn spawn(Self, String, Bool, (Int32, String) -> Unit) -> String?
  /// Stops every running command.
  fn kill_all(Self) -> Unit
}

///|
/// What ninja needs from the operating system. The `cli` package holds all
/// of ninja's command-line behavior and does no I/O itself.
pub(all) struct Host {
  disk : &@moonja.Disk
  files : &@moonja.FileReader
  terminal : &@moonja.Terminal
  processes : &Processes
  platform : @moonja.Platform
  /// Changes the working directory; an error message on failure.
  chdir : (String) -> String?
  getenv : (String) -> String?
  /// The working directory, as getcwd() spells it.
  cwd : () -> String
  /// Monotonic milliseconds.
  now_millis : () -> Int64
  /// Monotonic nanoseconds, for `-d stats`.
  now_nanos : () -> Int64
  processor_count : Int32
  /// The one-minute load average; negative if unknown.
  load_average : () -> Double
  /// Calls the handler when the user interrupts (Ctrl-C).
  on_interrupt : (() -> Unit) -> Unit
  /// Ends the process with the exit code once output is flushed.
  exit : (Int32) -> Unit
}

///|
/// Ends ninja with an exit code. Raised from anywhere in a step and turned
/// into `Host::exit` where the host called in.
priv suberror Quit {
  Quit(Int32)
}

///|
/// Runs `body`, ending the process if it quits.
fn Host::run_guarded(self : Host, body : () -> Unit raise Quit) -> Unit {
  body() catch {
    Quit(code) => (self.exit)(code)
  }
}

///|
/// `ninja: fatal: ...` and exit 1.
fn Host::fatal(self : Host, message : String) -> Unit raise Quit {
  self.terminal.write_err("ninja: fatal: \{message}\n")
  raise Quit(1)
}

///|
fn Host::error(self : Host, message : String) -> Unit {
  self.terminal.write_err("ninja: error: \{message}\n")
}

///|
fn Host::warning(self : Host, message : String) -> Unit {
  self.terminal.write_err("ninja: warning: \{message}\n")
}

///|
fn Host::print(self : Host, text : String) -> Unit {
  self.terminal.write_out(text)
}
