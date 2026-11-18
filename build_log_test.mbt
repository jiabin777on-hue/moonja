// Ported from ninja v1.13.2 src/build_log_test.cc (Apache-2.0, see NOTICE).
// The log file lives on a MemoryDisk instead of the real file system.

///|
let log_file : String = "BuildLogTest-tempfile"

///|
/// StateTestWithBuiltinRules: a state with a `cat` rule.
fn state_with_cat(input : String) -> @moonja.State raise {
  let state = @moonja.State::new()
  let parser = @moonja.ManifestParser::without_files(state)
  parser.parse_test("rule cat\n  command = cat $in > $out\n")
  parser.parse_test(input)
  state
}

///|
fn never_dead(_path : String) -> Bool {
  false
}

///|
fn hash_hex(command : String) -> String {
  @moonja.hash_command(command).to_string(radix=16)
}

///|
test "BuildLogTest.WriteRead" {
  let state = state_with_cat("build out: cat mid\nbuild mid: cat in\n")
  let disk = @moonja.MemoryDisk::new()
  let log1 = @moonja.BuildLog::new()
  log1.open_for_write(disk, log_file, never_dead)
  log1.record_command(disk, state.edges()[0], 15, 18)
  log1.record_command(disk, state.edges()[1], 20, 25)
  log1.close(disk)
  let log2 = @moonja.BuildLog::new()
  assert_eq(log2.load(disk, log_file), (Success, ""))
  assert_eq(log1.entries().length(), 2)
  assert_eq(log2.entries().length(), 2)
  let e1 = log1.lookup_by_output("out").unwrap()
  let e2 = log2.lookup_by_output("out").unwrap()
  assert_eq(e1, e2)
  assert_eq(e1.start_time, 15)
  assert_eq(e1.output, "out")
}

///|
test "BuildLogTest.FirstWriteAddsSignature" {
  let disk = @moonja.MemoryDisk::new()
  let log = @moonja.BuildLog::new()
  log.open_for_write(disk, log_file, never_dead)
  log.close(disk)
  assert_eq(disk.contents(log_file), Some("# ninja log v7\n"))
  // Opening the file again does not add a second signature.
  log.open_for_write(disk, log_file, never_dead)
  log.close(disk)
  assert_eq(disk.contents(log_file), Some("# ninja log v7\n"))
}

///|
test "BuildLogTest.DoubleEntry" {
  let disk = @moonja.MemoryDisk::new()
  disk.create(
    log_file,
    "# ninja log v7\n0\t1\t2\tout\t\{hash_hex("command abc")}\n0\t1\t2\tout\t\{hash_hex("command def")}\n",
  )
  let log = @moonja.BuildLog::new()
  assert_eq(log.load(disk, log_file), (Success, ""))
  let entry = log.lookup_by_output("out").unwrap()
  assert_eq(entry.command_hash, @moonja.hash_command("command def"))
}

///|
test "BuildLogTest.Truncate" {
  let state = state_with_cat("build out: cat mid\nbuild mid: cat in\n")
  let disk = @moonja.MemoryDisk::new()
  let log1 = @moonja.BuildLog::new()
  log1.open_for_write(disk, log_file, never_dead)
  log1.record_command(disk, state.edges()[0], 15, 18)
  log1.record_command(disk, state.edges()[1], 20, 25)
  log1.close(disk)
  let size = disk.contents(log_file).unwrap().length()
  assert_true(size > 0)
  // Every truncation of the file must load without crashing.
  for keep = size; keep > 0; keep = keep - 1 {
    let log2 = @moonja.BuildLog::new()
    log2.open_for_write(disk, log_file, never_dead)
    log2.record_command(disk, state.edges()[0], 15, 18)
    log2.record_command(disk, state.edges()[1], 20, 25)
    log2.close(disk)
    let contents = disk.contents(log_file).unwrap()
    disk.create(log_file, contents.unsafe_substring(start=0, end=keep))
    let log3 = @moonja.BuildLog::new()
    let (status, message) = log3.load(disk, log_file)
    assert_true(status is Success || message != "")
  }
}

///|
test "BuildLogTest.ObsoleteOldVersion" {
  let disk = @moonja.MemoryDisk::new()
  disk.create(log_file, "# ninja log v3\n123 456 0 out command\n")
  let log = @moonja.BuildLog::new()
  let (_, message) = log.load(disk, log_file)
  assert_true(message.contains("version"))
}

///|
test "BuildLogTest.SpacesInOutput" {
  let disk = @moonja.MemoryDisk::new()
  disk.create(
    log_file,
    "# ninja log v7\n123\t456\t456\tout with space\t\{hash_hex("command")}\n",
  )
  let log = @moonja.BuildLog::new()
  assert_eq(log.load(disk, log_file), (Success, ""))
  let entry = log.lookup_by_output("out with space").unwrap()
  assert_eq(entry.start_time, 123)
  assert_eq(entry.end_time, 456)
  assert_eq(entry.mtime, 456)
  assert_eq(entry.command_hash, @moonja.hash_command("command"))
}

///|
test "BuildLogTest.DuplicateVersionHeader" {
  // Old ninja versions wrote several headers on Windows; later ones are
  // ignored.
  let disk = @moonja.MemoryDisk::new()
  disk.create(
    log_file,
    "# ninja log v7\n123\t456\t456\tout\t\{hash_hex("command")}\n# ninja log v7\n456\t789\t789\tout2\t\{hash_hex("command2")}\n",
  )
  let log = @moonja.BuildLog::new()
  assert_eq(log.load(disk, log_file), (Success, ""))
  let entry = log.lookup_by_output("out").unwrap()
  assert_eq((entry.start_time, entry.end_time, entry.mtime), (123, 456, 456))
  assert_eq(entry.command_hash, @moonja.hash_command("command"))
  let entry = log.lookup_by_output("out2").unwrap()
  assert_eq((entry.start_time, entry.end_time, entry.mtime), (456, 789, 789))
  assert_eq(entry.command_hash, @moonja.hash_command("command2"))
}

///|
test "BuildLogTest.Restat" {
  let disk = @moonja.MemoryDisk::new()
  disk.create(log_file, "# ninja log v7\n1\t2\t3\tout\tcommand\n")
  let log = @moonja.BuildLog::new()
  assert_eq(log.load(disk, log_file), (Success, ""))
  assert_eq(log.lookup_by_output("out").unwrap().mtime, 3)
  // ninja's TestDiskInterface reports mtime 4 for every file.
  disk.set_mtime("out", 4)
  log.restat(disk, log_file, ["out2"])
  // Unchanged: the filter does not match.
  assert_eq(log.lookup_by_output("out").unwrap().mtime, 3)
  log.restat(disk, log_file, [])
  assert_eq(log.lookup_by_output("out").unwrap().mtime, 4)
}

///|
test "BuildLogTest.VeryLongInputLine" {
  // Lines longer than ninja's 256 KiB buffer are ignored without affecting
  // the other lines.
  let line = StringBuilder()
  line.write_string("# ninja log v7\n123\t456\t456\tout\tcommand start")
  for _ in 0..<(512 * 1024 / " more_command".length()) {
    line.write_string(" more_command")
  }
  line.write_string("\n456\t789\t789\tout2\t\{hash_hex("command2")}\n")
  let disk = @moonja.MemoryDisk::new()
  disk.create(log_file, line.to_string())
  let log = @moonja.BuildLog::new()
  assert_eq(log.load(disk, log_file), (Success, ""))
  assert_true(log.lookup_by_output("out") is None)
  let entry = log.lookup_by_output("out2").unwrap()
  assert_eq((entry.start_time, entry.end_time, entry.mtime), (456, 789, 789))
  assert_eq(entry.command_hash, @moonja.hash_command("command2"))
}

///|
test "BuildLogTest.MultiTargetEdge" {
  let state = state_with_cat("build out out.d: cat\n")
  let disk = @moonja.MemoryDisk::new()
  let log = @moonja.BuildLog::new()
  log.record_command(disk, state.edges()[0], 21, 22)
  assert_eq(log.entries().length(), 2)
  let e1 = log.lookup_by_output("out").unwrap()
  let e2 = log.lookup_by_output("out.d").unwrap()
  assert_eq(e1.output, "out")
  assert_eq(e2.output, "out.d")
  assert_eq(e1.start_time, 21)
  assert_eq(e2.start_time, 21)
  assert_eq(e2.end_time, 22)
}

///|
test "BuildLogRecompactTest.Recompact" {
  let state = state_with_cat("build out: cat in\nbuild out2: cat in\n")
  let disk = @moonja.MemoryDisk::new()
  let is_dead = fn(path : String) { path == "out2" }
  let log1 = @moonja.BuildLog::new()
  log1.open_for_write(disk, log_file, is_dead)
  // Record the same edge many times so the next open recompacts.
  for i in 0..<200 {
    log1.record_command(disk, state.edges()[0], 15, 18 + i)
  }
  log1.record_command(disk, state.edges()[1], 21, 22)
  log1.close(disk)
  let log2 = @moonja.BuildLog::new()
  assert_eq(log2.load(disk, log_file), (Success, ""))
  assert_eq(log2.entries().length(), 2)
  assert_true(log2.lookup_by_output("out") is Some(_))
  assert_true(log2.lookup_by_output("out2") is Some(_))
  // Force the recompaction.
  log2.open_for_write(disk, log_file, is_dead)
  log2.close(disk)
  // "out2" is dead and was removed.
  assert_eq(log2.load(disk, log_file), (Success, ""))
  assert_eq(log2.entries().length(), 1)
  assert_true(log2.lookup_by_output("out") is Some(_))
  assert_true(log2.lookup_by_output("out2") is None)
}
