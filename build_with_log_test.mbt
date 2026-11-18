// Ported from ninja v1.13.2 src/build_test.cc: BuildWithLogTest, BuildDryRun
// and the response file, interrupt and stat failure cases of BuildTest
// (Apache-2.0, see NOTICE). Test names follow the original.

///|
/// BuildWithLogTest: a build fixture whose builder records to a build log.
fn build_with_log(
  dry_run~ : Bool = false,
) -> (BuildFixture, @moonja.BuildLog) raise {
  let f = build_fixture()
  f.config.dry_run = dry_run
  let log = @moonja.BuildLog::new()
  f.builder.set_build_log(Some(log))
  (f, log)
}

///|
/// What the tests do between builds: clear commands, reset the state,
/// clean up and reset the plan.
fn BuildFixture::cleanup(self : BuildFixture) -> Unit {
  self.again()
  self.builder.cleanup(self.runner)
  self.builder.plan().reset()
}

///|
test "BuildWithLogTest.ImplicitGeneratedOutOfDate" {
  let (f, _) = build_with_log()
  f.parse(
    "rule touch\n  command = touch $out\n  generator = 1\nbuild out.imp: touch | in\n",
  )
  f.fs.create("out.imp", "")
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.add_target("out.imp")
  assert_false(f.builder.already_up_to_date())
  assert_true(f.node("out.imp").dirty())
}

///|
test "BuildWithLogTest.ImplicitGeneratedOutOfDate2" {
  let (f, _) = build_with_log()
  f.parse(
    "rule touch-implicit-dep-out\n  command = sleep 1 ; touch $test_dependency ; sleep 1 ; touch $out\n  generator = 1\nbuild out.imp: touch-implicit-dep-out | inimp inimp2\n  test_dependency = inimp\n",
  )
  f.fs.create("inimp", "")
  f.fs.create("out.imp", "")
  ignore(f.fs.tick())
  f.fs.create("inimp2", "")
  ignore(f.fs.tick())
  f.add_target("out.imp")
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build().0, Success)
  assert_true(f.builder.already_up_to_date())
  f.cleanup()
  f.add_target("out.imp")
  assert_true(f.builder.already_up_to_date())
  assert_false(f.node("out.imp").dirty())
  f.cleanup()
  ignore(f.fs.tick())
  f.fs.create("inimp", "")
  f.add_target("out.imp")
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build().0, Success)
  assert_true(f.builder.already_up_to_date())
  f.cleanup()
  f.add_target("out.imp")
  assert_true(f.builder.already_up_to_date())
  assert_false(f.node("out.imp").dirty())
}

///|
test "BuildWithLogTest.NotInLogButOnDisk" {
  let (f, _) = build_with_log()
  f.parse("rule cc\n  command = cc\nbuild out1: cc in\n")
  // Up to date if the command hash did not matter.
  f.fs.create("in", "")
  f.fs.create("out1", "")
  // Not in the log, so not up to date until built again.
  f.add_target("out1")
  assert_false(f.builder.already_up_to_date())
  f.again()
  f.add_target("out1")
  assert_eq(f.build().0, Success)
  assert_true(f.builder.already_up_to_date())
}

///|
test "BuildWithLogTest.RebuildAfterFailure" {
  let (f, _) = build_with_log()
  f.parse(
    "rule touch-fail-tick2\n  command = touch-fail-tick2\nbuild out1: touch-fail-tick2 in\n",
  )
  f.fs.create("in", "")
  // A successful run puts out1 in the log.
  f.add_target("out1")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
  f.cleanup()
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // A failure that updates the output's timestamp.
  f.add_target("out1")
  assert_eq(f.build(), (Failure, "subcommand failed"))
  assert_eq(f.runner.commands_ran.length(), 1)
  f.cleanup()
  ignore(f.fs.tick())
  // Runs again although the output is up to date on disk.
  f.add_target("out1")
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildWithLogTest.RebuildWithNoInputs" {
  let (f, _) = build_with_log()
  f.parse(
    "rule touch\n  command = touch\nbuild out1: touch\nbuild out2: touch in\n",
  )
  f.fs.create("in", "")
  f.add_target("out1")
  f.add_target("out2")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 2)
  f.again()
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.add_target("out1")
  f.add_target("out2")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
let restat_manifest : String =
  #|rule true
  #|  command = true
  #|  restat = 1
  #|rule cc
  #|  command = cc
  #|  restat = 1
  #|build out1: cc in
  #|build out2: true out1
  #|build out3: cat out2
  #|

///|
test "BuildWithLogTest.RestatTest" {
  let (f, _) = build_with_log()
  f.parse(restat_manifest)
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.fs.create("out3", "")
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // A first build puts the commands in the log; without log entries out3
  // would rebuild regardless of restat.
  f.add_target("out3")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 3)
  assert_eq(f.builder.plan().command_edge_count(), 3)
  f.again()
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // cc touches out1, so out2 is built; true does not touch out2, so out3
  // is cancelled.
  f.add_target("out3")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 2)
  // No-op: the log knows out2 was built with input timestamp 2.
  f.again()
  f.add_target("out3")
  assert_true(f.builder.already_up_to_date())
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // But a change of out1 still rebuilds out2.
  f.again()
  f.add_target("out3")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 2)
}

///|
test "BuildWithLogTest.RestatMissingFile" {
  // A restat rule that does not create its missing output counts as one
  // that left its output unchanged.
  let (f, _) = build_with_log()
  f.parse(
    "rule true\n  command = true\n  restat = 1\nrule cc\n  command = cc\nbuild out1: true in\nbuild out2: cc out1\n",
  )
  f.fs.create("in", "")
  f.fs.create("out2", "")
  f.add_target("out2")
  assert_eq(f.build(), (Success, ""))
  f.again()
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.fs.create("out2", "")
  // Only the first command runs: it does not touch its output.
  f.add_target("out2")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildWithLogTest.RestatSingleDependentOutputDirty" {
  let (f, _) = build_with_log()
  f.parse(
    "rule true\n  command = true\n  restat = 1\nrule touch\n  command = touch\nbuild out1: true in\nbuild out2 out3: touch out1\nbuild out4: touch out2\n",
  )
  f.fs.create("in", "")
  f.add_target("out4")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 3)
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.remove("out3")
  // out1 builds; out3 is missing so out2 and out3 build; then out4. The
  // restat of out1 must not clean the edge writing out2 and out3.
  f.again()
  f.add_target("out4")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 3)
}

///|
test "BuildWithLogTest.RestatMissingInput" {
  // https://github.com/ninja-build/ninja/issues/295: an input is removed
  // but the output does not change.
  let (f, log) = build_with_log()
  f.parse(
    "rule true\n  command = true\n  depfile = $out.d\n  restat = 1\nrule cc\n  command = cc\nbuild out1: true in\nbuild out2: cc out1\n",
  )
  f.fs.create("in", "")
  // The implicit deps and the depfile are newer than the output.
  let restat_mtime = f.fs.tick()
  f.fs.create("out1.d", "out1: will.be.deleted restat.file\n")
  f.fs.create("will.be.deleted", "")
  f.fs.create("restat.file", "")
  f.add_target("out2")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 2)
  // The log records the right mtime.
  assert_eq(log.lookup_by_output("out1").unwrap().mtime, restat_mtime)
  // Removing a depfile input dirties the target without changing it.
  f.remove("will.be.deleted")
  f.again()
  f.add_target("out2")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 1)
  assert_eq(log.lookup_by_output("out1").unwrap().mtime, restat_mtime)
}

///|
test "BuildWithLogTest.RestatInputChangesDueToRule" {
  let (f, log) = build_with_log()
  f.parse(
    "rule generate-depfile\n  command = sleep 1 ; touch $touch_dependency; touch $out ; echo \"$out: $test_dependency\" > $depfile\nbuild out1: generate-depfile || cat1\n  test_dependency = in2\n  touch_dependency = 1\n  restat = 1\n  depfile = out.d\n",
  )
  // out1 is a restat rule: the log records when its command finished, as
  // the command touches one of its discovered deps.
  f.add_target("out1")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 2)
  assert_eq(f.builder.plan().command_edge_count(), 2)
  assert_eq(log.lookup_by_output("out1").unwrap().mtime, 2)
  f.cleanup()
  ignore(f.fs.tick())
  f.fs.create("in1", "")
  // A dep of an order-only dep does not rebuild out1.
  f.add_target("out1")
  assert_false(f.state.get_node("out1", 0).dirty())
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
  assert_eq(f.builder.plan().command_edge_count(), 1)
}

///|
test "BuildWithLogTest.GeneratedPlainDepfileMtime" {
  let (f, _) = build_with_log()
  f.parse(
    "rule generate-depfile\n  command = touch $out ; echo \"$out: $test_dependency\" > $depfile\nbuild out: generate-depfile\n  test_dependency = inimp\n  depfile = out.d\n",
  )
  f.fs.create("inimp", "")
  ignore(f.fs.tick())
  f.add_target("out")
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build().0, Success)
  assert_true(f.builder.already_up_to_date())
  f.cleanup()
  f.add_target("out")
  assert_true(f.builder.already_up_to_date())
}

///|
test "BuildDryRun.AllCommandsShown" {
  let (f, _) = build_with_log(dry_run=true)
  f.parse(restat_manifest)
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.fs.create("out3", "")
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // A dry run cannot see that true leaves out2 alone: all three show.
  f.add_target("out3")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 3)
}

///|
test "BuildDryRun.WithDyndep" {
  let (f, _) = build_with_log(dry_run=true)
  f.parse(
    "rule touch\n  command = touch $out\nrule cp\n  command = cp $in $out\nbuild dd: cp dd-in\nbuild out: touch || dd\n  dyndep = dd\nbuild out-copy: cp out\n",
  )
  f.fs.create("dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep\n")
  f.add_target("out-copy")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 3)
}

///|
test "BuildTest.RspFileSuccess" {
  // Response files are created where needed and deleted on success.
  let f = build_fixture()
  f.parse(
    (
      #|rule cat_rsp
      #|  command = cat $rspfile > $out
      #|  rspfile = $rspfile
      #|  rspfile_content = $long_command
      #|rule cat_rsp_out
      #|  command = cat $rspfile > $out
      #|  rspfile = $out.rsp
      #|  rspfile_content = $long_command
      #|build out1: cat in
      #|build out2: cat_rsp in
      #|  rspfile = out 2.rsp
      #|  long_command = Some very long command
      #|build out$ 3: cat_rsp_out in
      #|  long_command = Some very long command
      #|
    ),
  )
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.fs.create("out 3", "")
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.add_target("out1")
  f.add_target("out2")
  f.add_target("out 3")
  let created = f.fs.files_created().length()
  let removed = f.fs.files_removed().length()
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 3)
  // The response files and the lock file to read the mtime were created.
  assert_eq(f.fs.files_created().length(), created + 3)
  for path in ["out 2.rsp", "out 3.rsp", ".ninja_lock"] {
    assert_true(f.fs.files_created().contains(path), msg=path)
  }
  // The response files were removed.
  assert_eq(f.fs.files_removed().length(), removed + 2)
  assert_true(f.fs.files_removed().contains("out 2.rsp"))
  assert_true(f.fs.files_removed().contains("out 3.rsp"))
}

///|
test "BuildTest.RspFileFailure" {
  // A failing command keeps its response file.
  let f = build_fixture()
  f.parse(
    "rule fail\n  command = fail\n  rspfile = $rspfile\n  rspfile_content = $long_command\nbuild out: fail in\n  rspfile = out.rsp\n  long_command = Another very long command\n",
  )
  f.fs.create("out", "")
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.add_target("out")
  let created = f.fs.files_created().length()
  let removed = f.fs.files_removed().length()
  assert_eq(f.build(), (Failure, "subcommand failed"))
  assert_eq(f.runner.commands_ran.length(), 1)
  assert_eq(f.fs.files_created().length(), created + 2)
  assert_true(f.fs.files_created().contains("out.rsp"))
  assert_true(f.fs.files_created().contains(".ninja_lock"))
  assert_eq(f.fs.files_removed().length(), removed)
  assert_false(f.fs.files_removed().contains("out.rsp"))
  assert_eq(f.fs.contents("out.rsp"), Some("Another very long command"))
}

///|
test "BuildWithLogTest.RspFileCmdLineChange" {
  // The response file's contents are part of the command line.
  let (f, log) = build_with_log()
  f.parse(
    "rule cat_rsp\n  command = cat $rspfile > $out\n  rspfile = $rspfile\n  rspfile_content = $long_command\nbuild out: cat_rsp in\n  rspfile = out.rsp\n  long_command = Original very long command\n",
  )
  f.fs.create("out", "")
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.add_target("out")
  // 1. The first build fills the log.
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 1)
  // 2. Nothing changed.
  f.again()
  f.add_target("out")
  assert_true(f.builder.already_up_to_date())
  // 3. A different command hash in the log rebuilds.
  let entry = log.lookup_by_output("out").unwrap()
  assert_eq(
    entry.command_hash,
    @moonja.hash_command("cat out.rsp > out;rspfile=Original very long command"),
  )
  entry.command_hash = entry.command_hash + 1
  f.again()
  f.add_target("out")
  assert_eq(f.build().0, Success)
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildTest.InterruptCleanup" {
  let f = build_fixture()
  f.parse(
    "rule interrupt\n  command = interrupt\nrule touch-interrupt\n  command = touch-interrupt\nbuild out1: interrupt in1\nbuild out2: touch-interrupt in2\n",
  )
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  ignore(f.fs.tick())
  f.fs.create("in1", "")
  f.fs.create("in2", "")
  // An untouched output of an interrupted command stays.
  f.add_target("out1")
  assert_eq(f.build(), (Interrupted, "interrupted by user"))
  f.builder.cleanup(f.runner)
  assert_true(@moonja.Disk::stat(f.fs, "out1") > 0)
  // A touched one is deleted.
  f.add_target("out2")
  assert_eq(f.build(), (Interrupted, "interrupted by user"))
  f.builder.cleanup(f.runner)
  assert_eq(@moonja.Disk::stat(f.fs, "out2"), 0)
}

///|
test "BuildTest.StatFailureAbortsBuild" {
  let too_long = "i".repeat(400)
  let f = build_fixture()
  f.parse("build \{too_long}: cat in\n")
  f.fs.create("in", "")
  f.fs.set_stat_error(too_long, "stat failed")
  assert_eq(f.add_target_error(too_long), "stat failed")
}

///|
test "BuildTest.PhonyWithNoInputs" {
  let f = build_fixture()
  f.parse(
    "build nonexistent: phony\nbuild out1: cat || nonexistent\nbuild out2: cat nonexistent\n",
  )
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  // out1 is up to date: its dirty order-only dep has nothing to do.
  f.add_target("out1")
  assert_true(f.builder.already_up_to_date())
  // out2 is not: its input is dirty.
  f.again()
  f.add_target("out2")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildTest.DepsGccWithEmptyDepfileErrorsOut" {
  let f = build_fixture()
  f.parse("rule cc\n  command = cc\n  deps = gcc\nbuild out: cc\n")
  f.dirty("out")
  f.add_target("out")
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build(), (Failure, "subcommand failed"))
  assert_eq(f.runner.commands_ran.length(), 1)
}
