// Ported from ninja v1.13.2 src/deps_log_test.cc (Apache-2.0, see NOTICE).
// The log file lives on a MemoryDisk instead of the real file system.

///|
let deps_file : String = "DepsLogTest-tempfile"

///|
fn deps_paths(deps : @moonja.Deps) -> Array[String] {
  deps.nodes().map(fn(n) { n.path() })
}

///|
fn file_size(disk : @moonja.MemoryDisk, path : String) -> Int32 {
  disk.bytes(path).unwrap().length()
}

///|
/// The two-output log several tests start from.
fn write_two_outputs(disk : @moonja.MemoryDisk) -> Unit raise {
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.h", 0),
    state.get_node("bar.h", 0),
  ])
  log.record_deps(disk, state.get_node("out2.o", 0), 2, [
    state.get_node("foo.h", 0),
    state.get_node("bar2.h", 0),
  ])
  log.close(disk)
}

///|
test "DepsLogTest.WriteRead" {
  let disk = @moonja.MemoryDisk::new()
  let state1 = @moonja.State::new()
  let log1 = @moonja.DepsLog::new()
  log1.open_for_write(disk, deps_file)
  log1.record_deps(disk, state1.get_node("out.o", 0), 1, [
    state1.get_node("foo.h", 0),
    state1.get_node("bar.h", 0),
  ])
  log1.record_deps(disk, state1.get_node("out2.o", 0), 2, [
    state1.get_node("foo.h", 0),
    state1.get_node("bar2.h", 0),
  ])
  let deps = log1.get_deps(state1.get_node("out.o", 0)).unwrap()
  assert_eq(deps.mtime(), 1)
  assert_eq(deps_paths(deps), ["foo.h", "bar.h"])
  log1.close(disk)
  let state2 = @moonja.State::new()
  let log2 = @moonja.DepsLog::new()
  assert_eq(log2.load(disk, deps_file, state2), (Success, ""))
  assert_eq(log1.nodes().length(), log2.nodes().length())
  for i, node1 in log1.nodes() {
    assert_eq(node1.id(), i)
    assert_eq(log2.nodes()[i].id(), node1.id())
  }
  let deps = log2.get_deps(state2.get_node("out2.o", 0)).unwrap()
  assert_eq(deps.mtime(), 2)
  assert_eq(deps_paths(deps), ["foo.h", "bar2.h"])
}

///|
test "DepsLogTest.LotsOfDeps" {
  let count = 100000 // More than 64k.
  let disk = @moonja.MemoryDisk::new()
  let state1 = @moonja.State::new()
  let log1 = @moonja.DepsLog::new()
  log1.open_for_write(disk, deps_file)
  let deps = Array::makei(count, fn(i) { state1.get_node("file\{i}.h", 0) })
  log1.record_deps(disk, state1.get_node("out.o", 0), 1, deps)
  assert_eq(
    log1.get_deps(state1.get_node("out.o", 0)).unwrap().nodes().length(),
    count,
  )
  log1.close(disk)
  let state2 = @moonja.State::new()
  let log2 = @moonja.DepsLog::new()
  assert_eq(log2.load(disk, deps_file, state2), (Success, ""))
  assert_eq(
    log2.get_deps(state2.get_node("out.o", 0)).unwrap().nodes().length(),
    count,
  )
}

///|
test "DepsLogTest.DoubleEntry" {
  // Recording the same deps again does not grow the file.
  let disk = @moonja.MemoryDisk::new()
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.h", 0),
    state.get_node("bar.h", 0),
  ])
  log.close(disk)
  let size = file_size(disk, deps_file)
  assert_true(size > 0)
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  ignore(log.load(disk, deps_file, state))
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.h", 0),
    state.get_node("bar.h", 0),
  ])
  log.close(disk)
  assert_eq(file_size(disk, deps_file), size)
}

///|
let deps_manifest : String =
  #|rule cc
  #|  command = cc
  #|  deps = gcc
  #|build out.o: cc
  #|build other_out.o: cc
  #|

///|
fn parsed_state() -> @moonja.State raise {
  let state = @moonja.State::new()
  @moonja.ManifestParser::without_files(state).parse_test(deps_manifest)
  state
}

///|
test "DepsLogTest.Recompact" {
  let disk = @moonja.MemoryDisk::new()
  // Write some deps and note the size.
  let state = parsed_state()
  let log = @moonja.DepsLog::new()
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.h", 0),
    state.get_node("bar.h", 0),
  ])
  log.record_deps(disk, state.get_node("other_out.o", 0), 1, [
    state.get_node("foo.h", 0),
    state.get_node("baz.h", 0),
  ])
  log.close(disk)
  let size1 = file_size(disk, deps_file)
  assert_true(size1 > 0)

  // Reload and record slightly different deps: the file grows.
  let state = parsed_state()
  let log = @moonja.DepsLog::new()
  ignore(log.load(disk, deps_file, state))
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.h", 0),
  ])
  log.close(disk)
  let size2 = file_size(disk, deps_file)
  assert_true(size2 > size1)

  // Reload: the new deps replaced the old. Then recompact.
  let state = parsed_state()
  let log = @moonja.DepsLog::new()
  ignore(log.load(disk, deps_file, state))
  let out = state.get_node("out.o", 0)
  let other_out = state.get_node("other_out.o", 0)
  let check = fn() raise {
    let deps = log.get_deps(out).unwrap()
    assert_eq(deps.mtime(), 1)
    assert_eq(deps_paths(deps), ["foo.h"])
    let deps = log.get_deps(other_out).unwrap()
    assert_eq(deps.mtime(), 1)
    assert_eq(deps_paths(deps), ["foo.h", "baz.h"])
  }
  check()
  log.recompact(disk, deps_file)
  // The in-memory graph is still valid after recompaction.
  check()
  assert_true(physical_equal(log.nodes()[out.id()], out))
  assert_true(physical_equal(log.nodes()[other_out.id()], other_out))
  let size3 = file_size(disk, deps_file)
  assert_true(size3 < size2)

  // Reload without the manifest and recompact: the entries are dead.
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  ignore(log.load(disk, deps_file, state))
  let out = state.get_node("out.o", 0)
  let other_out = state.get_node("other_out.o", 0)
  assert_eq(deps_paths(log.get_deps(out).unwrap()), ["foo.h"])
  assert_eq(deps_paths(log.get_deps(other_out).unwrap()), ["foo.h", "baz.h"])
  log.recompact(disk, deps_file)
  assert_true(log.get_deps(out) is None)
  assert_true(log.get_deps(other_out) is None)
  // The headers lose their ids too.
  assert_eq(state.lookup_node("foo.h").unwrap().id(), -1)
  assert_eq(state.lookup_node("baz.h").unwrap().id(), -1)
  assert_true(file_size(disk, deps_file) < size3)
}

///|
test "DepsLogTest.InvalidHeader" {
  let headers : Array[Bytes] = [
    b"", // Empty file.
     b"# ninjad", // Truncated first line.
     b"# ninjadeps\n", // No version int.
     b"# ninjadeps\n\x01\x02", // Truncated version int.
     b"# ninjadeps\n\x01\x02\x03\x04", // Invalid version int.
  ]
  for header in headers {
    let disk = @moonja.MemoryDisk::new()
    disk.create_bytes(deps_file, header)
    let log = @moonja.DepsLog::new()
    assert_eq(
      log.load(disk, deps_file, @moonja.State::new()),
      (Success, "bad deps log signature or version; starting over"),
    )
  }
}

///|
test "DepsLogTest.Truncated" {
  let disk = @moonja.MemoryDisk::new()
  write_two_outputs(disk)
  let full = disk.bytes(deps_file).unwrap()
  // Fewer nodes and deps survive as the file gets shorter.
  let mut node_count = 5
  let mut deps_count = 2
  for size = full.length(); size > 0; size = size - 1 {
    disk.create_bytes(deps_file, full[0:size].to_owned())
    let state = @moonja.State::new()
    let log = @moonja.DepsLog::new()
    let (_, message) = log.load(disk, deps_file, state)
    if message != "" {
      // Eventually the log is too short to parse.
      break
    }
    assert_true(node_count >= log.nodes().length())
    node_count = log.nodes().length()
    let new_deps_count = log.deps().filter(fn(d) { d is Some(_) }).length()
    assert_true(deps_count >= new_deps_count)
    deps_count = new_deps_count
  }
}

///|
test "DepsLogTest.TruncatedRecovery" {
  let disk = @moonja.MemoryDisk::new()
  write_two_outputs(disk)
  // Cut the last record short.
  @moonja.Disk::truncate_file(disk, deps_file, file_size(disk, deps_file) - 2)
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  assert_eq(
    log.load(disk, deps_file, state),
    (Success, "premature end of file; recovering"),
  )
  // The damaged entry is gone.
  assert_true(log.get_deps(state.get_node("out2.o", 0)) is None)
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out2.o", 0), 3, [
    state.get_node("foo.h", 0),
    state.get_node("bar2.h", 0),
  ])
  log.close(disk)
  // Appending after the damaged entry works.
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  ignore(log.load(disk, deps_file, state))
  assert_true(log.get_deps(state.get_node("out2.o", 0)) is Some(_))
}

///|
test "DepsLogTest.ReverseDepsNodes" {
  let disk = @moonja.MemoryDisk::new()
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.h", 0),
    state.get_node("bar.h", 0),
  ])
  log.record_deps(disk, state.get_node("out2.o", 0), 2, [
    state.get_node("foo.h", 0),
    state.get_node("bar2.h", 0),
  ])
  log.close(disk)
  let rev = log.get_first_reverse_deps_node(state.get_node("foo.h", 0)).unwrap()
  assert_true(
    physical_equal(rev, state.get_node("out.o", 0)) ||
    physical_equal(rev, state.get_node("out2.o", 0)),
  )
  let rev = log.get_first_reverse_deps_node(state.get_node("bar.h", 0)).unwrap()
  assert_true(physical_equal(rev, state.get_node("out.o", 0)))
}

///|
test "DepsLogTest.MalformedDepsLog" {
  let disk = @moonja.MemoryDisk::new()
  let state = @moonja.State::new()
  let log = @moonja.DepsLog::new()
  log.open_for_write(disk, deps_file)
  log.record_deps(disk, state.get_node("out.o", 0), 1, [
    state.get_node("foo.hh", 0),
    state.get_node("bar.hpp", 0),
  ])
  log.close(disk)
  let original = disk.bytes(deps_file).unwrap()
  // The exact bytes ninja writes.
  assert_eq(original[0:12].to_owned(), b"# ninjadeps\n")
  assert_eq(original[12:16].to_owned(), b"\x04\x00\x00\x00")
  // size 12, "out.o" and 3 bytes of padding, checksum ~0.
  assert_eq(
    original[16:32].to_owned(),
    b"\x0c\x00\x00\x00out.o\x00\x00\x00\xff\xff\xff\xff",
  )
  // size 12, "foo.hh" and 2 bytes of padding, checksum ~1.
  assert_eq(
    original[32:48].to_owned(),
    b"\x0c\x00\x00\x00foo.hh\x00\x00\xfe\xff\xff\xff",
  )
  let bad_file = "DepsLogTest-corrupted.tempfile"
  let load_bad = fn(contents : Bytes) raise {
    disk.create_bytes(bad_file, contents)
    @moonja.DepsLog::new().load(disk, bad_file, @moonja.State::new())
  }
  let corrupt = fn(at : Int32, values : Array[Byte]) {
    let bytes = original.to_array()
    for i, value in values {
      bytes[at + i] = value
    }
    Bytes::from_array(bytes)
  }
  // A corrupted header.
  assert_eq(
    load_bad(corrupt(0, [b'@'])),
    (Success, "bad deps log signature or version; starting over"),
  )
  // A truncated version.
  assert_eq(
    load_bad(original[0:15].to_owned()),
    (Success, "bad deps log signature or version; starting over"),
  )
  // A truncated size field of the first record: recovered silently.
  assert_eq(load_bad(original[0:19].to_owned()), (Success, ""))
  // A corrupted size of the first record.
  assert_eq(
    load_bad(corrupt(16, [b'\x55', b'\xaa', b'\xff', b'\xff'])),
    (Success, "premature end of file; recovering"),
  )
  // A first record size below 4.
  assert_eq(
    load_bad(corrupt(16, [b'\x01'])),
    (Success, "premature end of file; recovering"),
  )
}
