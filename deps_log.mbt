///|
let deps_signature : Bytes = b"# ninjadeps\n"

///|
let deps_version : Int32 = 4

///|
/// Records are limited to less than 2^19 bytes, like ninja's buffers.
let deps_max_record_size : Int32 = (1 << 19) - 1

///|
/// The dependencies discovered for one output, and its mtime when they
/// were recorded.
pub struct Deps {
  mtime : Int64
  nodes : Array[Node]
}

///|
pub fn Deps::mtime(self : Deps) -> Int64 {
  self.mtime
}

///|
pub fn Deps::nodes(self : Deps) -> Array[Node] {
  self.nodes
}

///|
/// `.ninja_deps`: discovered dependencies (from depfiles or /showIncludes)
/// in ninja's binary format v4. Every path gets an id; records are
/// little-endian 32-bit words.
pub struct DepsLog {
  mut nodes : Array[Node]
  mut deps : Array[Deps?]
  /// The file to open on the next write.
  mut pending_path : String
  /// The open file, if any.
  mut file : String?
  mut needs_recompaction : Bool
}

///|
pub fn DepsLog::new() -> DepsLog {
  {
    nodes: [],
    deps: [],
    pending_path: "",
    file: None,
    needs_recompaction: false,
  }
}

///|
/// Nodes by id.
pub fn DepsLog::nodes(self : DepsLog) -> Array[Node] {
  self.nodes
}

///|
/// Deps by node id.
pub fn DepsLog::deps(self : DepsLog) -> Array[Deps?] {
  self.deps
}

///|
fn push_u32(out : Array[Byte], value : UInt32) -> Unit {
  out.push((value & 0xff).to_byte())
  out.push(((value >> 8) & 0xff).to_byte())
  out.push(((value >> 16) & 0xff).to_byte())
  out.push(((value >> 24) & 0xff).to_byte())
}

///|
fn read_u32(data : Bytes, at : Int32) -> UInt32 {
  data[at].to_uint() |
  (data[at + 1].to_uint() << 8) |
  (data[at + 2].to_uint() << 16) |
  (data[at + 3].to_uint() << 24)
}

///|
pub fn[D : Disk] DepsLog::open_for_write(
  self : DepsLog,
  disk : D,
  path : String,
) -> Unit raise NinjaError {
  if self.needs_recompaction {
    self.recompact(disk, path)
  }
  // The file is opened on the first write.
  self.pending_path = path
}

///|
fn[D : Disk] DepsLog::open_if_needed(
  self : DepsLog,
  disk : D,
) -> Unit raise NinjaError {
  if self.pending_path == "" {
    return
  }
  let path = self.pending_path
  match disk.read_bytes(path) {
    None => {
      let header = []
      for b in deps_signature {
        header.push(b)
      }
      push_u32(header, deps_version.reinterpret_as_uint())
      disk.append_bytes(path, Bytes::from_array(header))
    }
    Some(existing) =>
      if existing.length() == 0 {
        let header = []
        for b in deps_signature {
          header.push(b)
        }
        push_u32(header, deps_version.reinterpret_as_uint())
        disk.append_bytes(path, Bytes::from_array(header))
      }
  }
  self.file = Some(path)
  self.pending_path = ""
}

///|
fn[D : Disk] DepsLog::write(
  self : DepsLog,
  disk : D,
  record : Array[Byte],
) -> Unit raise NinjaError {
  self.open_if_needed(disk)
  match self.file {
    Some(path) => disk.append_bytes(path, Bytes::from_array(record))
    None => raise Error("deps log is not open")
  }
}

///|
/// Gives `node` the next id, writing a path record.
fn[D : Disk] DepsLog::record_id(
  self : DepsLog,
  disk : D,
  node : Node,
) -> Unit raise NinjaError {
  let path = encode_bytes(node.path)
  let path_size = path.length()
  let padding = (4 - path_size % 4) % 4
  let size = path_size + padding + 4
  if size > deps_max_record_size {
    raise Error("deps log record too large for \{node.path}")
  }
  let record = []
  push_u32(record, size.reinterpret_as_uint())
  for b in path {
    record.push(b)
  }
  for _ in 0..<padding {
    record.push(b'\x00')
  }
  let id = self.nodes.length()
  push_u32(record, id.reinterpret_as_uint().lnot())
  self.write(disk, record)
  node.id = id
  self.nodes.push(node)
}

///|
/// Records that `node`, with `mtime`, depends on `nodes`. Nothing is written
/// when the log already says so.
pub fn[D : Disk] DepsLog::record_deps(
  self : DepsLog,
  disk : D,
  node : Node,
  mtime : Int64,
  nodes : Array[Node],
) -> Unit raise NinjaError {
  let mut made_change = false
  if node.id < 0 {
    self.record_id(disk, node)
    made_change = true
  }
  for dep in nodes {
    if dep.id < 0 {
      self.record_id(disk, dep)
      made_change = true
    }
  }
  if !made_change {
    match self.get_deps(node) {
      None => made_change = true
      Some(deps) =>
        if deps.mtime != mtime || deps.nodes.length() != nodes.length() {
          made_change = true
        } else {
          for i in 0..<nodes.length() {
            if !physical_equal(deps.nodes[i], nodes[i]) {
              made_change = true
              break
            }
          }
        }
    }
  }
  if !made_change {
    return
  }
  let size = 4 * (1 + 2 + nodes.length())
  if size > deps_max_record_size {
    raise Error("deps log record too large for \{node.path}")
  }
  let record = []
  // The high bit marks a deps record.
  push_u32(record, size.reinterpret_as_uint() | 0x80000000)
  push_u32(record, node.id.reinterpret_as_uint())
  let bits = mtime.reinterpret_as_uint64()
  push_u32(record, (bits & 0xffffffff).to_uint())
  push_u32(record, (bits >> 32).to_uint())
  for dep in nodes {
    push_u32(record, dep.id.reinterpret_as_uint())
  }
  self.write(disk, record)
  ignore(self.update_deps(node.id, { mtime, nodes: nodes.copy(), }))
}

///|
/// Closes the log, creating the file even if nothing was recorded.
pub fn[D : Disk] DepsLog::close(
  self : DepsLog,
  disk : D,
) -> Unit raise NinjaError {
  self.open_if_needed(disk)
  self.file = None
}

///|
/// Stores `deps` for `out_id`; true if it replaced earlier deps.
fn DepsLog::update_deps(self : DepsLog, out_id : Int32, deps : Deps) -> Bool {
  while self.deps.length() <= out_id {
    self.deps.push(None)
  }
  let replaced = self.deps[out_id] is Some(_)
  self.deps[out_id] = Some(deps)
  replaced
}

///|
pub fn DepsLog::get_deps(self : DepsLog, node : Node) -> Deps? {
  if node.id < 0 || node.id >= self.deps.length() {
    None
  } else {
    self.deps[node.id]
  }
}

///|
/// Some output whose deps include `node`.
pub fn DepsLog::get_first_reverse_deps_node(
  self : DepsLog,
  node : Node,
) -> Node? {
  for id, entry in self.deps {
    if entry is Some(deps) &&
      deps.nodes.iter().any(fn(n) { physical_equal(n, node) }) {
      return Some(self.nodes[id])
    }
  }
  None
}

///|
/// Loads `path` into `state`. A file with a bad header is deleted and a
/// damaged tail is cut off; both are reported as a message, not a failure.
pub fn[D : Disk] DepsLog::load(
  self : DepsLog,
  disk : D,
  path : String,
  state : State,
) -> (LoadStatus, String) raise NinjaError {
  let metric = metric_record(".ninja_deps load")
  defer metric.stop()
  guard disk.read_bytes(path) is Some(data) else { return (NotFound, "") }
  let len = data.length()
  let signature_size = deps_signature.length()
  let valid_header = len >= signature_size &&
    data[0:signature_size] == deps_signature[:]
  let version = if len >= signature_size + 4 {
    read_u32(data, signature_size).reinterpret_as_int()
  } else {
    0
  }
  if !valid_header || version != deps_version {
    let message = if version == 1 {
      "deps log version change; rebuilding"
    } else {
      "bad deps log signature or version; starting over"
    }
    ignore(disk.remove_file(path))
    // Not a failure: an empty deps log just rebuilds the outputs.
    return (Success, message)
  }
  let mut pos = signature_size + 4
  let mut offset = pos
  let mut read_failed = false
  let mut unique_dep_record_count = 0
  let mut total_dep_record_count = 0
  while true {
    if len - pos < 4 {
      // A partial size field is the end of the file, as with fread().
      break
    }
    let header = read_u32(data, pos)
    pos += 4
    let is_deps = header >> 31 != 0
    let size = (header & 0x7FFFFFFF).reinterpret_as_int()
    if size > deps_max_record_size || len - pos < size {
      read_failed = true
      break
    }
    let record = pos
    pos += size
    offset += size + 4
    if is_deps {
      if size % 4 != 0 || size < 12 {
        read_failed = true
        break
      }
      let out_id = read_u32(data, record).reinterpret_as_int()
      let mtime = ((read_u32(data, record + 8).to_uint64() << 32) |
      read_u32(data, record + 4).to_uint64()).reinterpret_as_int64()
      let count = size / 4 - 3
      let nodes = []
      for i in 0..<count {
        let id = read_u32(data, record + 12 + 4 * i).reinterpret_as_int()
        if id < 0 || id >= self.nodes.length() {
          read_failed = true
          break
        }
        nodes.push(self.nodes[id])
      }
      if read_failed || out_id < 0 {
        read_failed = true
        break
      }
      total_dep_record_count += 1
      if !self.update_deps(out_id, { mtime, nodes, }) {
        unique_dep_record_count += 1
      }
    } else {
      let mut path_size = size - 4
      if path_size <= 0 {
        read_failed = true
        break
      }
      // Up to 3 bytes of padding.
      for _ in 0..<3 {
        if path_size > 0 && data[record + path_size - 1] == b'\x00' {
          path_size -= 1
        }
      }
      let subpath = decode_bytes(data[record:record + path_size])
      // slash_bits do not matter here: the node is either in the manifest
      // already or an implicit dependency that never reaches a command.
      let node = state.get_node(subpath, 0)
      // The checksum catches two ninja processes writing concurrently.
      let checksum = read_u32(data, record + size - 4)
      let expected_id = checksum.lnot().reinterpret_as_int()
      let id = self.nodes.length()
      if id != expected_id || node.id >= 0 {
        read_failed = true
        break
      }
      node.id = id
      self.nodes.push(node)
    }
  }
  if read_failed {
    // Recover by cutting the file after the last complete record.
    disk.truncate_file(path, offset)
    return (Success, "premature end of file; recovering")
  }
  // Rewrite the log when most of its records are dead.
  let min_compaction_entry_count = 1000
  let compaction_ratio = 3
  if total_dep_record_count > min_compaction_entry_count &&
    total_dep_record_count > unique_dep_record_count * compaction_ratio {
    self.needs_recompaction = true
  }
  (Success, "")
}

///|
/// Whether `node` still needs its deps: it is built by an edge with `deps`.
pub fn is_deps_entry_live_for(node : Node) -> Bool raise NinjaError {
  match node.in_edge {
    Some(edge) => edge.get_binding("deps") != ""
    None => false
  }
}

///|
/// Rewrites the log with only the live entries, renumbering the nodes.
pub fn[D : Disk] DepsLog::recompact(
  self : DepsLog,
  disk : D,
  path : String,
) -> Unit raise NinjaError {
  let metric = metric_record(".ninja_deps recompact")
  defer metric.stop()
  self.close(disk)
  let temp = path + ".recompact"
  // Do not append to a file left over by a crashed recompaction.
  ignore(disk.remove_file(temp))
  let new_log = DepsLog::new()
  new_log.open_for_write(disk, temp)
  // New ids refer to the order in the new log.
  for node in self.nodes {
    node.id = -1
  }
  for old_id, entry in self.deps {
    guard entry is Some(deps) else { continue }
    if !is_deps_entry_live_for(self.nodes[old_id]) {
      continue
    }
    new_log.record_deps(disk, self.nodes[old_id], deps.mtime, deps.nodes)
  }
  new_log.close(disk)
  self.deps = new_log.deps
  self.nodes = new_log.nodes
  if disk.remove_file(path) < 0 {
    raise Error("cannot remove \{path}")
  }
  disk.rename_file(temp, path)
}
