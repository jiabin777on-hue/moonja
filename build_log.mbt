///|
let build_log_version : Int32 = 7

///|
let build_log_signature : String = "# ninja log v"

///|
/// ninja reads the log through a fixed 256 KiB buffer; longer lines are
/// dropped.
let build_log_buffer_size : Int32 = 256 * 1024

///|
/// One output's record in `.ninja_log`.
#derive(Eq, Debug)
pub(all) struct LogEntry {
  output : String
  mut command_hash : UInt64
  mut start_time : Int32
  mut end_time : Int32
  mut mtime : Int64
}

///|
#derive(Eq, Debug)
pub(all) enum LoadStatus {
  Success
  NotFound
}

///|
/// `.ninja_log`: for each output, the hash of the command that last built
/// it and when. Port of ninja's `BuildLog` (format v7).
pub struct BuildLog {
  entries : Map[String, LogEntry]
  mut path : String
  mut opened : Bool
  mut needs_recompaction : Bool
}

///|
pub fn BuildLog::new() -> BuildLog {
  { entries: Map([]), path: "", opened: false, needs_recompaction: false, }
}

///|
pub fn BuildLog::entries(self : BuildLog) -> Map[String, LogEntry] {
  self.entries
}

///|
pub fn BuildLog::lookup_by_output(self : BuildLog, path : String) -> LogEntry? {
  self.entries.get(path)
}

///|
fn write_entry(entry : LogEntry) -> String {
  "\{entry.start_time}\t\{entry.end_time}\t\{entry.mtime}\t\{entry.output}\t\{entry.command_hash.to_string(radix=16)}\n"
}

///|
/// Prepares to append to `path`, first rewriting it without redundant or
/// dead entries if loading found that worthwhile. `is_path_dead` tells
/// which outputs no longer exist in the manifest.
pub fn[D : Disk] BuildLog::open_for_write(
  self : BuildLog,
  disk : D,
  path : String,
  is_path_dead : (String) -> Bool,
) -> Unit raise NinjaError {
  if self.needs_recompaction {
    self.recompact(disk, path, is_path_dead)
  }
  // The file is opened on the first write.
  self.path = path
}

///|
fn[D : Disk] BuildLog::open_if_needed(
  self : BuildLog,
  disk : D,
) -> Unit raise NinjaError {
  if self.opened || self.path == "" {
    return
  }
  match disk.read_file(self.path) {
    None | Some("") =>
      disk.append_file(
        self.path,
        "\{build_log_signature}\{build_log_version}\n",
      )
    Some(_) => ()
  }
  self.opened = true
}

///|
/// Records that `edge` ran from `start_time` to `end_time` (milliseconds
/// since the build started) and left its outputs with `mtime`.
pub fn[D : Disk] BuildLog::record_command(
  self : BuildLog,
  disk : D,
  edge : Edge,
  start_time : Int32,
  end_time : Int32,
  mtime~ : Int64 = 0,
) -> Unit raise NinjaError {
  let command_hash = hash_command(edge.evaluate_command(incl_rsp_file=true))
  for out in edge.outputs {
    let entry = match self.entries.get(out.path) {
      Some(entry) => entry
      None => {
        let entry = {
          output: out.path,
          command_hash: 0,
          start_time: 0,
          end_time: 0,
          mtime: 0,
        }
        self.entries[out.path] = entry
        entry
      }
    }
    entry.command_hash = command_hash
    entry.start_time = start_time
    entry.end_time = end_time
    entry.mtime = mtime
    self.open_if_needed(disk)
    if self.opened {
      disk.append_file(self.path, write_entry(entry))
    }
  }
}

///|
/// Closes the log, creating the file even if nothing was recorded.
pub fn[D : Disk] BuildLog::close(
  self : BuildLog,
  disk : D,
) -> Unit raise NinjaError {
  self.open_if_needed(disk)
  self.opened = false
}

///|
/// ninja's `LineReader`: yields (line start, newline position or -1) over
/// `content` as it would come through a 256 KiB buffer.
priv struct LineReader {
  content : String
  mut read_to : Int32
  mut buf_end : Int32
  mut line_start : Int32
  mut line_end : Int32
}

///|
fn LineReader::new(content : String) -> LineReader {
  { content, read_to: 0, buf_end: 0, line_start: 0, line_end: -1, }
}

///|
fn LineReader::find_newline(self : LineReader, from : Int32) -> Int32 {
  for i in from..<self.buf_end {
    if self.content.unsafe_get(i) == '\n' {
      return i
    }
  }
  -1
}

///|
fn LineReader::read_line(self : LineReader) -> Bool {
  let len = self.content.length()
  if self.line_start >= self.buf_end || self.line_end < 0 {
    // Refill the empty buffer.
    let start = self.read_to
    let end = if start + build_log_buffer_size < len {
      start + build_log_buffer_size
    } else {
      len
    }
    if end == start {
      return false
    }
    self.read_to = end
    self.line_start = start
    self.buf_end = end
  } else {
    self.line_start = self.line_end + 1
  }
  self.line_end = self.find_newline(self.line_start)
  if self.line_end < 0 {
    // Keep the partial line and fill the rest of the buffer.
    let end = if self.line_start + build_log_buffer_size < len {
      self.line_start + build_log_buffer_size
    } else {
      len
    }
    self.read_to = end
    self.buf_end = end
    self.line_end = self.find_newline(self.line_start)
  }
  true
}

///|
/// C `strtoll`/`strtoull` in base 10 or 16, without overflow handling
/// beyond wrapping.
fn parse_c_integer(
  text : String,
  start : Int32,
  end : Int32,
  base : Int32,
) -> UInt64 {
  let mut i = start
  while i < end && (text.unsafe_get(i) == ' ' || text.unsafe_get(i) == '\t') {
    i += 1
  }
  let mut negative = false
  if i < end && (text.unsafe_get(i) == '-' || text.unsafe_get(i) == '+') {
    negative = text.unsafe_get(i) == '-'
    i += 1
  }
  if base == 16 &&
    i + 1 < end &&
    text.unsafe_get(i) == '0' &&
    (text.unsafe_get(i + 1) == 'x' || text.unsafe_get(i + 1) == 'X') {
    i += 2
  }
  let mut value : UInt64 = 0
  while i < end {
    let c = text.unsafe_get(i).to_int()
    let digit = if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else if base == 16 && c >= 'a'.to_int() && c <= 'f'.to_int() {
      c - 'a'.to_int() + 10
    } else if base == 16 && c >= 'A'.to_int() && c <= 'F'.to_int() {
      c - 'A'.to_int() + 10
    } else {
      break
    }
    value = value * base.to_uint64() + digit.to_uint64()
    i += 1
  }
  if negative {
    0UL - value
  } else {
    value
  }
}

///|
fn find_tab(text : String, from : Int32, end : Int32) -> Int32 {
  for i in from..<end {
    if text.unsafe_get(i) == '\t' {
      return i
    }
  }
  -1
}

///|
/// Loads `path`. A log of another format version is deleted and reported
/// as `NotFound` with a message; outputs will simply be rebuilt.
pub fn[D : Disk] BuildLog::load(
  self : BuildLog,
  disk : D,
  path : String,
) -> (LoadStatus, String) raise NinjaError {
  guard disk.read_file(path) is Some(content) else { return (NotFound, "") }
  let mut log_version = 0
  let mut unique_entry_count = 0
  let mut total_entry_count = 0
  let mut read_any = false
  let reader = LineReader::new(content)
  while reader.read_line() {
    read_any = true
    let line_start = reader.line_start
    let line_end = reader.line_end
    if log_version == 0 {
      // sscanf("# ninja log v%d\n") on the first line.
      if content.unsafe_substring(
          start=line_start,
          end=@cmp.minimum(
            line_start + build_log_signature.length(),
            content.length(),
          ),
        ) ==
        build_log_signature {
        let digits_start = line_start + build_log_signature.length()
        log_version = parse_c_integer(
            content,
            digits_start,
            content.length(),
            10,
          )
          .reinterpret_as_int64()
          .to_int()
      }
      let message = if log_version < build_log_version {
        "build log version is too old; starting over"
      } else if log_version > build_log_version {
        "build log version is too new; starting over"
      } else {
        ""
      }
      if message != "" {
        ignore(disk.remove_file(path))
        return (NotFound, message)
      }
    }
    if line_end < 0 {
      continue
    }
    let t1 = find_tab(content, line_start, line_end)
    if t1 < 0 {
      continue
    }
    let start_time = parse_c_integer(content, line_start, t1, 10)
      .reinterpret_as_int64()
      .to_int()
    let t2 = find_tab(content, t1 + 1, line_end)
    if t2 < 0 {
      continue
    }
    let end_time = parse_c_integer(content, t1 + 1, t2, 10)
      .reinterpret_as_int64()
      .to_int()
    let t3 = find_tab(content, t2 + 1, line_end)
    if t3 < 0 {
      continue
    }
    let mtime = parse_c_integer(content, t2 + 1, t3, 10).reinterpret_as_int64()
    let t4 = find_tab(content, t3 + 1, line_end)
    if t4 < 0 {
      continue
    }
    let output = content.unsafe_substring(start=t3 + 1, end=t4)
    let entry = match self.entries.get(output) {
      Some(entry) => entry
      None => {
        let entry = {
          output,
          command_hash: 0,
          start_time: 0,
          end_time: 0,
          mtime: 0,
        }
        self.entries[output] = entry
        unique_entry_count += 1
        entry
      }
    }
    total_entry_count += 1
    entry.start_time = start_time
    entry.end_time = end_time
    entry.mtime = mtime
    entry.command_hash = parse_c_integer(content, t4 + 1, line_end, 16)
  }
  if !read_any {
    // The file was empty.
    return (Success, "")
  }
  // Rewrite the log when upgrading it or when it has grown redundant.
  let min_compaction_entry_count = 100
  let compaction_ratio = 3
  if log_version < build_log_version {
    self.needs_recompaction = true
  } else if total_entry_count > min_compaction_entry_count &&
    total_entry_count > unique_entry_count * compaction_ratio {
    self.needs_recompaction = true
  }
  (Success, "")
}

///|
/// Rewrites the log with one entry per live output.
pub fn[D : Disk] BuildLog::recompact(
  self : BuildLog,
  disk : D,
  path : String,
  is_path_dead : (String) -> Bool,
) -> Unit raise NinjaError {
  self.close(disk)
  let out = StringBuilder()
  out.write_string("\{build_log_signature}\{build_log_version}\n")
  let dead = []
  for output, entry in self.entries {
    if is_path_dead(output) {
      dead.push(output)
      continue
    }
    out.write_string(write_entry(entry))
  }
  for output in dead {
    self.entries.remove(output)
  }
  let temp = path + ".recompact"
  if !disk.write_file(temp, out.to_string()) {
    raise Error("cannot write \{temp}")
  }
  if disk.remove_file(path) < 0 {
    raise Error("cannot remove \{path}")
  }
  disk.rename_file(temp, path)
}

///|
/// Updates the recorded mtimes from the disk (`ninja -t restat`), for the
/// given outputs or, when `outputs` is empty, for all of them.
pub fn[D : Disk] BuildLog::restat(
  self : BuildLog,
  disk : D,
  path : String,
  outputs : Array[String],
) -> Unit raise NinjaError {
  self.close(disk)
  let out = StringBuilder()
  out.write_string("\{build_log_signature}\{build_log_version}\n")
  for output, entry in self.entries {
    if outputs.is_empty() || outputs.contains(output) {
      entry.mtime = disk.stat(output)
    }
    out.write_string(write_entry(entry))
  }
  let temp = path + ".restat"
  if !disk.write_file(temp, out.to_string()) {
    raise Error("cannot write \{temp}")
  }
  if disk.remove_file(path) < 0 {
    raise Error("cannot remove \{path}")
  }
  disk.rename_file(temp, path)
}
