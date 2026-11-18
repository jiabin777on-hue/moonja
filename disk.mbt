///|
/// The file system as ninja uses it: ninja's `DiskInterface`, plus the
/// append, rename and truncate operations its logs perform with stdio.
/// Modification times are integers whose unit the host chooses; 0 means
/// "missing". Text is UTF-8.
pub(open) trait Disk {
  /// The mtime of `path`, 0 if it does not exist.
  fn stat(Self, String) -> Int64 raise NinjaError
  /// Creates one directory; false on failure.
  fn make_dir(Self, String) -> Bool
  /// Replaces the contents of `path`; false on failure.
  fn write_file(Self, String, String) -> Bool
  /// The contents of `path`, None if it does not exist.
  fn read_file(Self, String) -> String? raise NinjaError
  /// The raw contents of `path`, None if it does not exist.
  fn read_bytes(Self, String) -> Bytes? raise NinjaError
  /// 0 if removed, 1 if it did not exist, -1 on error (ninja's convention).
  fn remove_file(Self, String) -> Int32
  /// Appends to `path`, creating it if needed.
  fn append_bytes(Self, String, Bytes) -> Unit raise NinjaError
  /// Replaces `to` with `from`.
  fn rename_file(Self, String, String) -> Unit raise NinjaError
  /// Cuts `path` to its first `size` bytes.
  fn truncate_file(Self, String, Int32) -> Unit raise NinjaError
}

///|
/// Appends UTF-8 text.
pub fn[D : Disk] append_text(
  disk : D,
  path : String,
  text : String,
) -> Unit raise NinjaError {
  disk.append_bytes(path, @utf8.encode(text))
}

///|
struct MemoryFile {
  mut mtime : Int64
  /// Appends are amortized O(1); `contents` copies out on demand.
  buffer : Buffer
  mut snapshot : Bytes?
  /// When set, `stat` fails with this message.
  mut stat_error : String
}

///|
fn MemoryFile::new(
  mtime : Int64,
  contents : Bytes,
  stat_error : String,
) -> MemoryFile {
  let buffer = Buffer(capacity=contents.length())
  buffer.write_bytes(contents)
  { mtime, buffer, snapshot: Some(contents), stat_error, }
}

///|
fn MemoryFile::contents(self : MemoryFile) -> Bytes {
  match self.snapshot {
    Some(bytes) => bytes
    None => {
      let bytes = self.buffer.to_bytes()
      self.snapshot = Some(bytes)
      bytes
    }
  }
}

///|
fn MemoryFile::replace(self : MemoryFile, contents : Bytes) -> Unit {
  self.buffer.reset()
  self.buffer.write_bytes(contents)
  self.snapshot = Some(contents)
}

///|
fn MemoryFile::append(self : MemoryFile, contents : Bytes) -> Unit {
  self.buffer.write_bytes(contents)
  self.snapshot = None
}

///|
/// An in-memory `Disk` with a logical clock, ported from ninja's test
/// `VirtualFileSystem`. It records what was read, created, removed and
/// which directories were made.
pub struct MemoryDisk {
  files : Map[String, MemoryFile]
  mut now : Int64
  directories_made : Array[String]
  files_read : Array[String]
  files_created : Array[String]
  files_removed : Array[String]
}

///|
pub fn MemoryDisk::new() -> MemoryDisk {
  {
    files: Map([]),
    now: 1,
    directories_made: [],
    files_read: [],
    files_created: [],
    files_removed: [],
  }
}

///|
/// Advances the clock; later writes are newer than earlier ones.
pub fn MemoryDisk::tick(self : MemoryDisk) -> Int64 {
  self.now += 1
  self.now
}

///|
pub fn MemoryDisk::now(self : MemoryDisk) -> Int64 {
  self.now
}

///|
/// Creates or replaces `path` with the current time as its mtime.
pub fn MemoryDisk::create_bytes(
  self : MemoryDisk,
  path : String,
  contents : Bytes,
) -> Unit {
  match self.files.get(path) {
    Some(file) => {
      file.mtime = self.now
      file.replace(contents)
    }
    None => self.files[path] = MemoryFile::new(self.now, contents, "")
  }
  if !self.files_created.contains(path) {
    self.files_created.push(path)
  }
}

///|
/// Creates or replaces `path` with UTF-8 text.
pub fn MemoryDisk::create(
  self : MemoryDisk,
  path : String,
  contents : String,
) -> Unit {
  self.create_bytes(path, @utf8.encode(contents))
}

///|
/// Makes `stat` of `path` fail with `message`.
pub fn MemoryDisk::set_stat_error(
  self : MemoryDisk,
  path : String,
  message : String,
) -> Unit {
  match self.files.get(path) {
    Some(file) => {
      file.mtime = -1
      file.stat_error = message
    }
    None => self.files[path] = MemoryFile::new(-1, b"", message)
  }
}

///|
pub fn MemoryDisk::set_mtime(
  self : MemoryDisk,
  path : String,
  mtime : Int64,
) -> Unit {
  match self.files.get(path) {
    Some(file) => file.mtime = mtime
    None => self.files[path] = MemoryFile::new(mtime, b"", "")
  }
}

///|
pub fn MemoryDisk::contents(self : MemoryDisk, path : String) -> String? {
  self.files.get(path).map(fn(file) { @utf8.decode_lossy(file.contents()) })
}

///|
pub fn MemoryDisk::bytes(self : MemoryDisk, path : String) -> Bytes? {
  self.files.get(path).map(fn(file) { file.contents() })
}

///|
pub fn MemoryDisk::exists(self : MemoryDisk, path : String) -> Bool {
  self.files.contains(path)
}

///|
pub fn MemoryDisk::files_read(self : MemoryDisk) -> Array[String] {
  self.files_read
}

///|
pub fn MemoryDisk::files_created(self : MemoryDisk) -> Array[String] {
  self.files_created
}

///|
pub fn MemoryDisk::files_removed(self : MemoryDisk) -> Array[String] {
  self.files_removed
}

///|
pub fn MemoryDisk::directories_made(self : MemoryDisk) -> Array[String] {
  self.directories_made
}

///|
pub impl Disk for MemoryDisk with fn stat(self, path) {
  match self.files.get(path) {
    Some(file) =>
      if file.stat_error != "" {
        raise Error(file.stat_error)
      } else {
        file.mtime
      }
    None => 0
  }
}

///|
pub impl Disk for MemoryDisk with fn make_dir(self, path) {
  self.directories_made.push(path)
  true
}

///|
pub impl Disk for MemoryDisk with fn write_file(self, path, contents) {
  self.create(path, contents)
  true
}

///|
pub impl Disk for MemoryDisk with fn read_file(self, path) {
  self.files_read.push(path)
  self.files.get(path).map(fn(file) { @utf8.decode_lossy(file.contents()) })
}

///|
pub impl Disk for MemoryDisk with fn read_bytes(self, path) {
  self.files_read.push(path)
  self.files.get(path).map(fn(file) { file.contents() })
}

///|
pub impl Disk for MemoryDisk with fn remove_file(self, path) {
  if self.directories_made.contains(path) {
    return -1
  }
  if self.files.contains(path) {
    self.files.remove(path)
    if !self.files_removed.contains(path) {
      self.files_removed.push(path)
    }
    0
  } else {
    1
  }
}

///|
pub impl Disk for MemoryDisk with fn append_bytes(self, path, contents) {
  match self.files.get(path) {
    Some(file) => {
      file.append(contents)
      file.mtime = self.now
    }
    None => self.create_bytes(path, contents)
  }
}

///|
pub impl Disk for MemoryDisk with fn rename_file(self, from, to) {
  guard self.files.get(from) is Some(file) else {
    raise Error("No such file or directory")
  }
  self.files.remove(from)
  self.files[to] = file
}

///|
pub impl Disk for MemoryDisk with fn truncate_file(self, path, size) {
  guard self.files.get(path) is Some(file) else {
    raise Error("No such file or directory")
  }
  let contents = file.contents()
  if size < contents.length() {
    file.replace(contents[0:size].to_owned())
  }
}

///|
pub impl FileReader for MemoryDisk with fn read_file(self, path) {
  self.files_read.push(path)
  match self.files.get(path) {
    Some(file) => @utf8.decode_lossy(file.contents())
    None => raise Error("No such file or directory")
  }
}
