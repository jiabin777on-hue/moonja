// Non-UTF-8 bytes in manifests, commands, depfiles and logs: ninja keeps
// them as raw bytes, so moonja must give back exactly the bytes it read.

///|
fn round_trip(bytes : Bytes) -> Bytes {
  @moonja.encode_bytes(@moonja.decode_bytes(bytes))
}

///|
test "decode_bytes keeps valid UTF-8 unchanged" {
  let text = "caf\u{E9} \u{4E2D}\u{6587} \u{1F600} \u{FFFD} ascii"
  let bytes = @utf8.encode(text)
  assert_eq(@moonja.decode_bytes(bytes), text)
  assert_eq(@moonja.encode_bytes(text), bytes)
}

///|
test "every single byte round-trips" {
  for b in 0..<256 {
    let bytes = Bytes::from_array([b.to_byte()])
    assert_eq(round_trip(bytes), bytes)
  }
}

///|
test "every byte pair round-trips" {
  for a in 0x80..<256 {
    for b in 0..<256 {
      let bytes = Bytes::from_array([a.to_byte(), b.to_byte()])
      assert_eq(round_trip(bytes), bytes)
    }
  }
}

///|
test "ill-formed sequences round-trip byte by byte" {
  let cases : Array[Bytes] = [
    b"caf\xE9.c", // Latin-1
     b"\xC0\x80", // overlong NUL
     b"\xE0\x80\xAF", // overlong '/'
     b"\xED\xA0\x80", // UTF-8-encoded high surrogate
     b"\xED\xB3\xA9", // the UTF-8 form of U+DCE9, an escape code unit
     b"\xF4\x90\x80\x80", // above U+10FFFF
     b"\xF5\xFF\xFE", // never valid
     b"\xE4\xB8", // truncated
     b"\xF0\x9F\x98", // truncated 4-byte
     b"a\xE4\xB8\xADb\xFFc\xF0\x9F\x98\x80", // mixed valid and invalid
     b"\xEF\xBF\xBD\xFF", // a real U+FFFD next to an invalid byte
  ]
  for bytes in cases {
    assert_eq(round_trip(bytes), bytes)
  }
}

///|
test "invalid bytes become escapes, valid ones characters" {
  let text = @moonja.decode_bytes(b"caf\xE9\xE4\xB8\xAD")
  assert_eq(text.length(), 5)
  assert_eq(text.unsafe_get(3).to_int(), 0xDCE9)
  assert_eq(text.unsafe_get(4).to_int(), 0x4E2D)
  // An escape that came from the UTF-8 form of a surrogate is three
  // escapes, not one code unit, so it cannot collide with byte 0xE9.
  let surrogate = @moonja.decode_bytes(b"\xED\xB3\xA9")
  assert_eq(surrogate.length(), 3)
  assert_eq(surrogate.unsafe_get(0).to_int(), 0xDCED)
}

///|
test "encode_bytes replaces lone surrogates that are not escapes" {
  let high = String::from_array([(0xD800).unsafe_to_char()])
  assert_eq(@moonja.encode_bytes(high), b"\xEF\xBF\xBD")
  let low = String::from_array([(0xDC41).unsafe_to_char()])
  assert_eq(@moonja.encode_bytes(low), b"\xEF\xBF\xBD")
}

///|
/// The case from the application: `build caf\xE9.o: cc caf\xE9.c` in a
/// Latin-1 manifest.
fn latin1_state(disk : @moonja.MemoryDisk) -> @moonja.State raise {
  disk.create_bytes(
    "build.ninja", b"rule cc\n  command = cc $in -o $out\n  depfile = $out.d\n  deps = gcc\nbuild caf\xE9.o: cc caf\xE9.c\n",
  )
  let state = @moonja.State::new()
  let parser = @moonja.ManifestParser::new(state, reader=disk)
  parser.load("build.ninja")
  state
}

///|
test "Latin-1 manifest: paths and command keep their bytes" {
  let disk = @moonja.MemoryDisk::new()
  let state = latin1_state(disk)
  let edge = state.edges()[0]
  assert_eq(@moonja.encode_bytes(edge.inputs()[0].path()), b"caf\xE9.c")
  let command = edge.evaluate_command()
  // Like ninja, bytes outside [A-Za-z0-9_+,-./] get the path quoted.
  assert_eq(@moonja.encode_bytes(command), b"cc 'caf\xE9.c' -o 'caf\xE9.o'")
  // ninja hashes the command's bytes.
  assert_eq(
    @moonja.hash_command(command),
    @moonja.rapidhash(b"cc 'caf\xE9.c' -o 'caf\xE9.o'"),
  )
}

///|
test "Latin-1 manifest: build log stores raw bytes and reloads" {
  let disk = @moonja.MemoryDisk::new()
  let state = latin1_state(disk)
  let log = @moonja.BuildLog::new()
  log.open_for_write(disk, ".ninja_log", fn(_) { false })
  log.record_command(disk, state.edges()[0], 1, 2, mtime=3)
  log.close(disk)
  let bytes = disk.bytes(".ninja_log").unwrap()
  let hash = @moonja.rapidhash(b"cc 'caf\xE9.c' -o 'caf\xE9.o'").to_string(
    radix=16,
  )
  assert_eq(
    bytes,
    @utf8.encode("# ninja log v7\n") +
    b"1\t2\t3\tcaf\xE9.o\t" +
    @utf8.encode(hash + "\n"),
  )
  let again = @moonja.BuildLog::new()
  assert_eq(again.load(disk, ".ninja_log"), (Success, ""))
  let entry = again
    .lookup_by_output(@moonja.decode_bytes(b"caf\xE9.o"))
    .unwrap()
  assert_eq(
    entry.command_hash,
    @moonja.hash_command(state.edges()[0].evaluate_command()),
  )
}

///|
test "Latin-1 depfile and deps log keep raw bytes" {
  let disk = @moonja.MemoryDisk::new()
  let state = latin1_state(disk)
  let depfile = @moonja.parse_depfile(
    @moonja.decode_bytes(b"caf\xE9.o: caf\xE9.c na\xEFve.h\n"),
  )
  assert_eq(@moonja.encode_bytes(depfile.outs[0]), b"caf\xE9.o")
  assert_eq(@moonja.encode_bytes(depfile.ins[1]), b"na\xEFve.h")
  let out = state.edges()[0].outputs()[0]
  let header = state.get_node(depfile.ins[1], 0)
  let log = @moonja.DepsLog::new()
  log.open_for_write(disk, ".ninja_deps")
  log.record_deps(disk, out, 7, [header])
  log.close(disk)
  let raw = disk.bytes(".ninja_deps").unwrap()
  // Path records hold the bytes: "caf\xE9.o" padded to 8.
  assert_true(contains_bytes(raw, b"caf\xE9.o"))
  assert_true(contains_bytes(raw, b"na\xEFve.h"))
  let state2 = latin1_state(disk)
  let log2 = @moonja.DepsLog::new()
  assert_eq(log2.load(disk, ".ninja_deps", state2), (Success, ""))
  let deps = log2.get_deps(state2.edges()[0].outputs()[0]).unwrap()
  assert_eq(deps.nodes().map(fn(n) { @moonja.encode_bytes(n.path()) }), [
    b"na\xEFve.h",
  ])
}

///|
fn contains_bytes(haystack : Bytes, needle : Bytes) -> Bool {
  let n = needle.length()
  for i in 0..<=(haystack.length() - n) {
    if haystack[i:i + n] == needle[:] {
      return true
    }
  }
  false
}
