// The Node.js host: file system, terminal and processes for the `cli`
// package. Every system call is synchronous except running commands,
// whose results come back through Node's event loop.

///|
/// Shared state for the JS side: Node modules, the last error, running
/// children and their output files.
extern "js" fn setup() -> Unit =
  #| () => {
  #|   if (typeof process.getBuiltinModule !== "function") {
  #|     process.stderr.write("ninja: fatal: moonja needs Node.js 22.3 or newer\n");
  #|     process.exit(1);
  #|   }
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const os = process.getBuiltinModule("node:os");
  #|   const path = process.getBuiltinModule("node:path");
  #|   const cp = process.getBuiltinModule("node:child_process");
  #|   const tty = process.getBuiltinModule("node:tty");
  #|   const windows = process.platform === "win32";
  #|   // strerror() texts, so messages match ninja's.
  #|   const posixText = {
  #|     ENOENT: "No such file or directory", EACCES: "Permission denied",
  #|     ENOTDIR: "Not a directory", EISDIR: "Is a directory",
  #|     EEXIST: "File exists", ENOSPC: "No space left on device",
  #|     EROFS: "Read-only file system", ENAMETOOLONG: "File name too long",
  #|     ELOOP: "Too many levels of symbolic links", EPERM: "Operation not permitted",
  #|     EBUSY: "Device or resource busy", ENOTEMPTY: "Directory not empty",
  #|     EMFILE: "Too many open files", EINVAL: "Invalid argument",
  #|     EIO: "Input/output error", EXDEV: "Invalid cross-device link",
  #|   };
  #|   const text = (e) => posixText[e && e.code] || (e && e.message) || String(e);
  #|   const writeAll = (fd, s) => {
  #|     const buf = Buffer.from(s, "utf8");
  #|     let off = 0;
  #|     while (off < buf.length) {
  #|       try {
  #|         off += fs.writeSync(fd, buf, off, buf.length - off);
  #|       } catch (e) {
  #|         if (e.code !== "EAGAIN") throw e;
  #|       }
  #|     }
  #|   };
  #|   globalThis.__moonja = {
  #|     fs, os, path, cp, tty, windows, text, writeAll,
  #|     // 0 ok, 1 missing, 2 error (message in `error`).
  #|     kind: 0, error: "",
  #|     children: new Set(), temps: new Set(), counter: 0,
  #|   };
  #|   process.on("exit", () => {
  #|     for (const t of globalThis.__moonja.temps) {
  #|       try { fs.unlinkSync(t); } catch {}
  #|     }
  #|   });
  #| }

///|
extern "js" fn last_kind() -> Int32 =
  #| () => globalThis.__moonja.kind

///|
extern "js" fn last_error() -> String =
  #| () => globalThis.__moonja.error

///|
extern "js" fn argv() -> FixedArray[String] =
  #| () => process.argv.slice(2)

///|
extern "js" fn is_windows() -> Bool =
  #| () => process.platform === "win32"

///|
/// ninja's mtime: nanoseconds on POSIX (1 for a zero mtime), FILETIME
/// ticks since 2000 on Windows; 0 if missing, -1 on error.
extern "js" fn js_stat(path : String) -> Int64 =
  #| (p) => {
  #|   const m = globalThis.__moonja;
  #|   m.kind = 0;
  #|   let st;
  #|   try {
  #|     st = m.fs.statSync(p, { bigint: true, throwIfNoEntry: false });
  #|   } catch (e) {
  #|     if (e.code === "ENOENT" || e.code === "ENOTDIR") return 0n;
  #|     m.kind = 2;
  #|     m.error = m.windows
  #|       ? `GetFileAttributesEx(${p}): ${e.message}`
  #|       : `stat(${p}): ${m.text(e)}`;
  #|     return -1n;
  #|   }
  #|   if (st === undefined) return 0n;
  #|   if (m.windows) {
  #|     // FILETIME (100ns since 1601) minus 400 years, as ninja does.
  #|     return st.mtimeNs / 100n - 9782968000000000n;
  #|   }
  #|   if (st.mtimeNs / 1000000000n === 0n) return 1n;
  #|   return st.mtimeNs;
  #| }

///|
extern "js" fn js_make_dir(path : String) -> Bool =
  #| (p) => {
  #|   const m = globalThis.__moonja;
  #|   try {
  #|     m.fs.mkdirSync(p);
  #|     return true;
  #|   } catch (e) {
  #|     return e.code === "EEXIST";
  #|   }
  #| }

///|
extern "js" fn js_write_file(path : String, contents : String) -> Bool =
  #| (p, s) => {
  #|   const m = globalThis.__moonja;
  #|   try {
  #|     m.fs.writeFileSync(p, s);
  #|     return true;
  #|   } catch (e) {
  #|     m.writeAll(2, `ninja: error: WriteFile(${p}): Unable to create file. ${m.text(e)}\n`);
  #|     return false;
  #|   }
  #| }

///|
/// The file's bytes; check `last_kind` for missing (1) or error (2).
extern "js" fn js_read_bytes(path : String) -> Bytes =
  #| (p) => {
  #|   const m = globalThis.__moonja;
  #|   m.kind = 0;
  #|   try {
  #|     return new Uint8Array(m.fs.readFileSync(p));
  #|   } catch (e) {
  #|     m.kind = e.code === "ENOENT" ? 1 : 2;
  #|     if (m.windows) {
  #|       // ninja reads with CreateFileA and reports FormatMessage's text,
  #|       // which ends in CRLF.
  #|       if (e.code === "ENOENT") {
  #|         const dir = m.path.dirname(m.path.resolve(p));
  #|         m.error = m.fs.existsSync(dir)
  #|           ? "The system cannot find the file specified.\r\n"
  #|           : "The system cannot find the path specified.\r\n";
  #|       } else if (e.code === "EACCES" || e.code === "EISDIR" || e.code === "EPERM") {
  #|         m.error = "Access is denied.\r\n";
  #|       } else {
  #|         m.error = `${e.message}\r\n`;
  #|       }
  #|     } else {
  #|       m.error = m.text(e);
  #|     }
  #|     return new Uint8Array(0);
  #|   }
  #| }

///|
extern "js" fn decode_utf8(bytes : Bytes) -> String =
  #| (b) => new TextDecoder("utf-8").decode(b)

///|
/// 0 removed, 1 missing, -1 error (reported like ninja's `RemoveFile`).
extern "js" fn js_remove_file(path : String) -> Int32 =
  #| (p) => {
  #|   const m = globalThis.__moonja;
  #|   try {
  #|     const st = m.fs.lstatSync(p, { throwIfNoEntry: false });
  #|     if (st === undefined) return 1;
  #|     if (st.isDirectory()) m.fs.rmdirSync(p);
  #|     else m.fs.unlinkSync(p);
  #|     return 0;
  #|   } catch (e) {
  #|     if (e.code === "ENOENT") return 1;
  #|     m.writeAll(2, `ninja: error: remove(${p}): ${m.text(e)}\n`);
  #|     return -1;
  #|   }
  #| }

///|
extern "js" fn js_append_bytes(path : String, bytes : Bytes) -> Bool =
  #| (p, b) => {
  #|   const m = globalThis.__moonja;
  #|   try {
  #|     m.fs.appendFileSync(p, b);
  #|     return true;
  #|   } catch (e) {
  #|     m.error = `${p}: ${m.text(e)}`;
  #|     return false;
  #|   }
  #| }

///|
extern "js" fn js_rename(from : String, to : String) -> Bool =
  #| (a, b) => {
  #|   const m = globalThis.__moonja;
  #|   try {
  #|     m.fs.renameSync(a, b);
  #|     return true;
  #|   } catch (e) {
  #|     m.error = m.text(e);
  #|     return false;
  #|   }
  #| }

///|
extern "js" fn js_truncate(path : String, size : Int32) -> Bool =
  #| (p, n) => {
  #|   const m = globalThis.__moonja;
  #|   try {
  #|     m.fs.truncateSync(p, n);
  #|     return true;
  #|   } catch (e) {
  #|     m.error = m.text(e);
  #|     return false;
  #|   }
  #| }

///|
extern "js" fn write_fd(fd : Int32, text : String) -> Unit =
  #| (fd, s) => globalThis.__moonja.writeAll(fd, s)

///|
/// Writes ninja's own text: Windows' C runtime text mode turns LF into
/// CRLF.
extern "js" fn write_text_fd(fd : Int32, text : String) -> Unit =
  #| (fd, s) => {
  #|   const m = globalThis.__moonja;
  #|   m.writeAll(fd, m.windows ? s.replace(/\n/g, "\r\n") : s);
  #| }

///|
/// ninja's smart terminal: stdout is a TTY and TERM is not "dumb".
extern "js" fn js_is_smart() -> Bool =
  #| () => {
  #|   const m = globalThis.__moonja;
  #|   const term = process.env.TERM;
  #|   if (!m.tty.isatty(1)) return false;
  #|   if (m.windows) return term !== "dumb";
  #|   return term !== undefined && term !== "dumb";
  #| }

///|
extern "js" fn clicolor_force() -> Bool =
  #| () => {
  #|   const v = process.env.CLICOLOR_FORCE;
  #|   return v !== undefined && v !== "0";
  #| }

///|
extern "js" fn js_width() -> Int32 =
  #| () => {
  #|   const m = globalThis.__moonja;
  #|   if (!m.tty.isatty(1)) return 0;
  #|   return process.stdout.columns || 0;
  #| }

///|
/// Starts a command; "" on success or the reason it could not start.
extern "js" fn js_spawn(
  command : String,
  use_console : Bool,
  on_exit : (Int32, Bytes) -> Unit,
) -> String =
  #| (command, useConsole, onExit) => {
  #|   const m = globalThis.__moonja;
  #|   let fd = -1;
  #|   let temp = null;
  #|   if (!useConsole) {
  #|     temp = m.path.join(m.os.tmpdir(), `moonja-${process.pid}-${m.counter++}.out`);
  #|     try {
  #|       fd = m.fs.openSync(temp, "w+");
  #|     } catch (e) {
  #|       return m.text(e);
  #|     }
  #|     m.temps.add(temp);
  #|   }
  #|   // stdin is empty; stdout and stderr share one file, like ninja's pipe.
  #|   const stdio = useConsole ? "inherit" : ["ignore", fd, fd];
  #|   let child;
  #|   try {
  #|     if (m.windows) {
  #|       // CreateProcess: the program is the first token, the rest of the
  #|       // command line goes through verbatim.
  #|       let file, raw, rest;
  #|       const s = command.replace(/^[ \t]+/, "");
  #|       if (s.startsWith('"')) {
  #|         const end = s.indexOf('"', 1);
  #|         raw = end < 0 ? s : s.slice(0, end + 1);
  #|         file = end < 0 ? s.slice(1) : s.slice(1, end);
  #|       } else {
  #|         const end = s.search(/[ \t]/);
  #|         raw = end < 0 ? s : s.slice(0, end);
  #|         file = raw;
  #|       }
  #|       rest = s.slice(raw.length).replace(/^[ \t]+/, "");
  #|       if (/\.(bat|cmd)$/i.test(file)) {
  #|         // CreateProcess hands batch files to cmd.exe.
  #|         child = m.cp.spawn(process.env.ComSpec || "cmd.exe",
  #|           ["/d", "/s", "/c", `"${command}"`],
  #|           { stdio, windowsVerbatimArguments: true, windowsHide: true });
  #|       } else {
  #|         child = m.cp.spawn(file, rest === "" ? [] : [rest],
  #|           { stdio, argv0: raw, windowsVerbatimArguments: true, windowsHide: true });
  #|       }
  #|     } else {
  #|       child = m.cp.spawn("/bin/sh", ["-c", command],
  #|         { stdio, detached: !useConsole });
  #|     }
  #|   } catch (e) {
  #|     if (fd >= 0) m.fs.closeSync(fd);
  #|     return m.text(e);
  #|   }
  #|   if (fd >= 0) m.fs.closeSync(fd);
  #|   child.moonjaConsole = useConsole;
  #|   m.children.add(child);
  #|   let done = false;
  #|   const finish = (code, prefix) => {
  #|     if (done) return;
  #|     done = true;
  #|     m.children.delete(child);
  #|     let out = new Uint8Array(0);
  #|     if (temp !== null) {
  #|       try { out = new Uint8Array(m.fs.readFileSync(temp)); } catch {}
  #|       try { m.fs.unlinkSync(temp); } catch {}
  #|       m.temps.delete(temp);
  #|     }
  #|     if (prefix !== "") out = new Uint8Array(Buffer.from(prefix, "utf8"));
  #|     onExit(code, out);
  #|   };
  #|   child.on("error", (e) => {
  #|     if (m.windows && e.code === "ENOENT") {
  #|       // ninja treats a missing program as a failed command.
  #|       finish(1, "CreateProcess failed: The system cannot find the file specified.\n");
  #|     } else {
  #|       finish(1, `${e.message}\n`);
  #|     }
  #|   });
  #|   child.on("exit", (code, signal) => {
  #|     let status;
  #|     if (code !== null) status = code;
  #|     else if (signal === "SIGINT" || signal === "SIGTERM" || signal === "SIGHUP") status = 130;
  #|     else status = 128 + (m.os.constants.signals[signal] || 0);
  #|     finish(status, "");
  #|   });
  #|   return "";
  #| }

///|
extern "js" fn js_kill_all() -> Unit =
  #| () => {
  #|   const m = globalThis.__moonja;
  #|   for (const child of m.children) {
  #|     // Console commands got the user's Ctrl-C themselves.
  #|     if (child.moonjaConsole) continue;
  #|     try {
  #|       if (m.windows) child.kill();
  #|       else process.kill(-child.pid, "SIGINT");
  #|     } catch {}
  #|   }
  #| }

///|
extern "js" fn js_chdir(dir : String) -> String =
  #| (dir) => {
  #|   try {
  #|     process.chdir(dir);
  #|     return "";
  #|   } catch (e) {
  #|     return globalThis.__moonja.text(e);
  #|   }
  #| }

///|
extern "js" fn env_has(name : String) -> Bool =
  #| (name) => process.env[name] !== undefined

///|
extern "js" fn env_get(name : String) -> String =
  #| (name) => process.env[name] ?? ""

///|
extern "js" fn js_now_millis() -> Int64 =
  #| () => BigInt(Math.floor(performance.now()))

///|
extern "js" fn js_processor_count() -> Int32 =
  #| () => {
  #|   const os = globalThis.__moonja.os;
  #|   return typeof os.availableParallelism === "function"
  #|     ? os.availableParallelism() : os.cpus().length;
  #| }

///|
extern "js" fn js_load_average() -> Double =
  #| () => globalThis.__moonja.windows ? -0.0 : globalThis.__moonja.os.loadavg()[0]

///|
extern "js" fn js_on_interrupt(handler : () -> Unit) -> Unit =
  #| (handler) => {
  #|   for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  #|     try { process.on(sig, () => handler()); } catch {}
  #|   }
  #| }

///|
extern "js" fn js_exit(code : Int32) -> Unit =
  #| (code) => process.exit(code)

///|
/// The file system through Node's `fs`.
struct NodeDisk {}

///|
impl @moonja.Disk for NodeDisk with fn stat(_self, path) {
  let mtime = js_stat(path)
  if mtime == -1 {
    raise @moonja.NinjaError::Error(last_error())
  }
  mtime
}

///|
impl @moonja.Disk for NodeDisk with fn make_dir(_self, path) {
  js_make_dir(path)
}

///|
impl @moonja.Disk for NodeDisk with fn write_file(_self, path, contents) {
  js_write_file(path, contents)
}

///|
impl @moonja.Disk for NodeDisk with fn read_file(_self, path) {
  let bytes = js_read_bytes(path)
  match last_kind() {
    0 => Some(decode_utf8(bytes))
    1 => None
    _ => raise @moonja.NinjaError::Error(last_error())
  }
}

///|
impl @moonja.Disk for NodeDisk with fn read_bytes(_self, path) {
  let bytes = js_read_bytes(path)
  match last_kind() {
    0 => Some(bytes)
    1 => None
    _ => raise @moonja.NinjaError::Error(last_error())
  }
}

///|
impl @moonja.Disk for NodeDisk with fn remove_file(_self, path) {
  js_remove_file(path)
}

///|
impl @moonja.Disk for NodeDisk with fn append_bytes(_self, path, bytes) {
  if !js_append_bytes(path, bytes) {
    raise @moonja.NinjaError::Error(last_error())
  }
}

///|
impl @moonja.Disk for NodeDisk with fn rename_file(_self, from, to) {
  if !js_rename(from, to) {
    raise @moonja.NinjaError::Error(last_error())
  }
}

///|
impl @moonja.Disk for NodeDisk with fn truncate_file(_self, path, size) {
  if !js_truncate(path, size) {
    raise @moonja.NinjaError::Error(last_error())
  }
}

///|
/// Reads manifests: a missing file is an error too.
impl @moonja.FileReader for NodeDisk with fn read_file(_self, path) {
  let bytes = js_read_bytes(path)
  match last_kind() {
    0 => decode_utf8(bytes)
    _ => raise @moonja.NinjaError::Error(last_error())
  }
}

///|
/// stdout and stderr.
struct NodeTerminal {
  smart : Bool
  color : Bool
}

///|
impl @moonja.Terminal for NodeTerminal with fn write_out(_self, text) {
  write_text_fd(1, text)
}

///|
impl @moonja.Terminal for NodeTerminal with fn write_command_output(_self, text) {
  write_fd(1, text)
}

///|
impl @moonja.Terminal for NodeTerminal with fn write_err(_self, text) {
  write_text_fd(2, text)
}

///|
impl @moonja.Terminal for NodeTerminal with fn is_smart(self) {
  self.smart
}

///|
impl @moonja.Terminal for NodeTerminal with fn supports_color(self) {
  self.color
}

///|
impl @moonja.Terminal for NodeTerminal with fn width(_self) {
  js_width()
}

///|
/// Child processes through Node's `child_process`.
struct NodeProcesses {}

///|
impl @cli.Processes for NodeProcesses with fn spawn(
  _self,
  command,
  use_console,
  on_exit,
) {
  let error = js_spawn(command, use_console, fn(code, output) {
    on_exit(code, decode_utf8(output))
  })
  if error == "" {
    None
  } else {
    Some(error)
  }
}

///|
impl @cli.Processes for NodeProcesses with fn kill_all(_self) {
  js_kill_all()
}

///|
fn main {
  setup()
  let disk = NodeDisk::{ }
  let smart = js_is_smart()
  let host : @cli.Host = {
    disk,
    files: disk,
    terminal: NodeTerminal::{ smart, color: smart || clicolor_force(), },
    processes: NodeProcesses::{ },
    platform: if is_windows() {
      Windows
    } else {
      Posix
    },
    chdir: fn(dir) {
      let error = js_chdir(dir)
      if error == "" {
        None
      } else {
        Some(error)
      }
    },
    getenv: fn(name) { if env_has(name) { Some(env_get(name)) } else { None } },
    now_millis: js_now_millis,
    processor_count: js_processor_count(),
    load_average: js_load_average,
    on_interrupt: js_on_interrupt,
    exit: js_exit,
  }
  @cli.run(host, Array::from_fixed_array(argv()))
}
