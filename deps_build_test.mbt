// Ported from ninja v1.13.2 src/build_test.cc: FailedDepsParse,
// BuildWithQueryDepsLogTest, BuildWithDepsLogTest and the restat/depfile
// cases (Apache-2.0, see NOTICE). Test names follow the original.

///|
let deps_file_path : String = "ninja_deps"

///|
let build_log_path : String = "build_log"

///|
/// A fresh state with `manifest` (and the cat rule unless told otherwise).
fn fresh_state(
  manifest : String,
  cat_rule~ : Bool = true,
  platform~ : @moonja.Platform = Posix,
) -> @moonja.State raise {
  let state = @moonja.State::new(platform~)
  let parser = @moonja.ManifestParser::without_files(state)
  if cat_rule {
    parser.parse_test("rule cat\n  command = cat $in > $out\n")
  }
  parser.parse_test(manifest)
  state
}

///|
/// A builder for `state` on the fixture's disk and config.
fn BuildFixture::builder_for(
  self : BuildFixture,
  state : @moonja.State,
  build_log? : @moonja.BuildLog,
  deps_log? : @moonja.DepsLog,
) -> @moonja.Builder {
  @moonja.Builder::new(state, self.config, self.fs, build_log?, deps_log?)
}

///|
/// Adds `target`, builds and expects success.
fn BuildFixture::build_ok(
  self : BuildFixture,
  builder : @moonja.Builder,
  target : String,
) -> Unit raise {
  ignore(builder.add_target_name(target))
  let (status, message) = builder.build(self.runner)
  assert_eq((status, message), (Success, ""))
  assert_eq(self.runner.errors, [])
}

///|
fn BuildFixture::open_deps_log(
  self : BuildFixture,
  state : @moonja.State,
  path~ : String = deps_file_path,
  load~ : Bool = true,
) -> @moonja.DepsLog raise {
  let log = @moonja.DepsLog::new()
  if load {
    ignore(log.load(self.fs, path, state))
  }
  log.open_for_write(self.fs, path)
  log
}

///|
fn deps_paths_of(log : @moonja.DepsLog, node : @moonja.Node) -> Array[String] {
  match log.get_deps(node) {
    Some(deps) => deps.nodes().map(fn(n) { n.path() })
    None => []
  }
}

///|
test "BuildTest.FailedDepsParse" {
  let f = build_fixture()
  f.parse("build bad_deps.o: cat in1\n  deps = gcc\n  depfile = in1.d\n")
  f.add_target("bad_deps.o")
  // Only one path may be left of the colon.
  f.fs.create("in1.d", "AAA BBB")
  assert_eq(f.build(), (Failure, "subcommand failed"))
}

///|
/// BuildWithQueryDepsLogTest: the fixture's builder records to a deps log.
fn query_fixture() -> (BuildFixture, @moonja.DepsLog) raise {
  let log = @moonja.DepsLog::new()
  let f = build_fixture(deps_log=log)
  log.open_for_write(f.fs, deps_file_path)
  (f, log)
}

///|
fn two_outputs(manifest : String, depfile : String?) -> Unit raise {
  let (f, log) = query_fixture()
  f.parse(manifest)
  f.add_target("out1")
  if depfile is Some(contents) {
    f.fs.create("in.d", contents)
  }
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
  let expected = if depfile is Some(_) { ["in1", "in2"] } else { ["in1"] }
  assert_eq(deps_paths_of(log, f.state.lookup_node("out1").unwrap()), expected)
  assert_eq(deps_paths_of(log, f.state.lookup_node("out2").unwrap()), expected)
}

///|
test "BuildWithQueryDepsLogTest.TwoOutputsDepFileMSVC" {
  // An escaped string keeps the trailing space of the prefix "using ",
  // which `moon fmt` would strip from a `#|` line.
  two_outputs(
    "rule cp_multi_msvc\n    command = echo 'using $in' && for file in $out; do cp $in $$file; done\n    deps = msvc\n    msvc_deps_prefix = using \nbuild out1 out2: cp_multi_msvc in1\n",
    None,
  )
}

///|
test "BuildWithQueryDepsLogTest.TwoOutputsDepFileGCCOneLine" {
  two_outputs(
    "rule cp_multi_gcc\n    command = echo '$out: $in' > in.d && for file in $out; do cp in1 $$file; done\n    deps = gcc\n    depfile = in.d\nbuild out1 out2: cp_multi_gcc in1 in2\n",
    Some("out1 out2: in1 in2"),
  )
}

///|
test "BuildWithQueryDepsLogTest.TwoOutputsDepFileGCCMultiLineInput" {
  two_outputs(
    "rule cp_multi_gcc\n    command = echo '$out: in1\\n$out: in2' > in.d && for file in $out; do cp in1 $$file; done\n    deps = gcc\n    depfile = in.d\nbuild out1 out2: cp_multi_gcc in1 in2\n",
    Some("out1 out2: in1\nout1 out2: in2"),
  )
}

///|
test "BuildWithQueryDepsLogTest.TwoOutputsDepFileGCCMultiLineOutput" {
  two_outputs(
    "rule cp_multi_gcc\n    command = echo 'out1: $in\\nout2: $in' > in.d && for file in $out; do cp in1 $$file; done\n    deps = gcc\n    depfile = in.d\nbuild out1 out2: cp_multi_gcc in1 in2\n",
    Some("out1: in1 in2\nout2: in1 in2"),
  )
}

///|
test "BuildWithQueryDepsLogTest.TwoOutputsDepFileGCCOnlyMainOutput" {
  two_outputs(
    "rule cp_multi_gcc\n    command = echo 'out1: $in' > in.d && for file in $out; do cp in1 $$file; done\n    deps = gcc\n    depfile = in.d\nbuild out1 out2: cp_multi_gcc in1 in2\n",
    Some("out1: in1 in2"),
  )
}

///|
test "BuildWithQueryDepsLogTest.TwoOutputsDepFileGCCOnlySecondaryOutput" {
  // The primary output is not mentioned, which still works.
  two_outputs(
    "rule cp_multi_gcc\n    command = echo 'out2: $in' > in.d && for file in $out; do cp in1 $$file; done\n    deps = gcc\n    depfile = in.d\nbuild out1 out2: cp_multi_gcc in1 in2\n",
    Some("out2: in1 in2"),
  )
}

///|
let cat_deps_manifest : String = "build out: cat in1\n  deps = gcc\n  depfile = in1.d\n"

///|
test "BuildWithDepsLogTest.Straightforward" {
  let f = build_fixture()
  // A first build records the deps.
  let state = fresh_state(cat_deps_manifest)
  let deps_log = f.open_deps_log(state, load=false)
  let builder = f.builder_for(state, deps_log~)
  ignore(builder.add_target_name("out"))
  f.fs.create("in1.d", "out: in2")
  let (status, _) = builder.build(f.runner)
  assert_eq(status, Success)
  // The depfile was removed; recreate it.
  assert_eq(@moonja.Disk::stat(f.fs, "in1.d"), 0)
  f.fs.create("in1.d", "out: in2")
  deps_log.close(f.fs)
  // Touch the file only the deps mention, and build again.
  let state = fresh_state(cat_deps_manifest)
  ignore(f.fs.tick())
  f.fs.create("in2", "")
  let deps_log = f.open_deps_log(state)
  f.runner.commands_ran.clear()
  f.build_ok(f.builder_for(state, deps_log~), "out")
  // in2 is newer, so out was rebuilt.
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildWithDepsLogTest.ObsoleteDeps" {
  // Deps recorded at an older time rebuild even with aligned files.
  let f = build_fixture()
  f.fs.create("in1", "")
  f.fs.create("in1.d", "out: ")
  let state = fresh_state(cat_deps_manifest)
  let deps_log = f.open_deps_log(state, load=false)
  f.build_ok(f.builder_for(state, deps_log~), "out")
  deps_log.close(f.fs)
  // Move every file a tick forward, so that only the deps are old.
  ignore(f.fs.tick())
  f.fs.create("in1", "")
  f.fs.create("out", "")
  // The depfile was removed.
  assert_eq(@moonja.Disk::stat(f.fs, "in1.d"), 0)
  let state = fresh_state(cat_deps_manifest)
  let deps_log = f.open_deps_log(state)
  let builder = f.builder_for(state, deps_log~)
  f.runner.commands_ran.clear()
  ignore(builder.add_target_name("out"))
  // The build expects the depfile.
  f.fs.create("in1.d", "out: ")
  let (status, _) = builder.build(f.runner)
  assert_eq(status, Success)
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildWithDepsLogTest.DepsIgnoredInDryRun" {
  let f = build_fixture()
  f.fs.create("out", "")
  ignore(f.fs.tick())
  f.fs.create("in1", "")
  let state = fresh_state(cat_deps_manifest)
  // A dry run has no deps log.
  f.config.dry_run = true
  f.runner.commands_ran.clear()
  f.build_ok(f.builder_for(state), "out")
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
fn open_build_log(fs : @moonja.MemoryDisk) -> @moonja.BuildLog raise {
  let log = @moonja.BuildLog::new()
  ignore(log.load(fs, build_log_path))
  log.open_for_write(fs, build_log_path, fn(_) { false })
  log
}

///|
test "BuildWithDepsLogTest.TestInputMtimeRaceCondition" {
  let f = build_fixture()
  let state = fresh_state(
    "rule long-cc\n  command = long-cc\nbuild out: long-cc in1\n  test_dependency = in1\n",
  )
  let build_log = open_build_log(f.fs)
  let deps_log = f.open_deps_log(state)
  // out is built; the log records mtime 1, the time of in1 when the
  // command started.
  f.runner.commands_ran.clear()
  f.build_ok(f.builder_for(state, build_log~, deps_log~), "out")
  assert_eq(f.runner.commands_ran.length(), 1)
  assert_eq(build_log.lookup_by_output("out").unwrap().mtime, 1)
  // in1 changed during the build, so out rebuilds although newer.
  f.runner.commands_ran.clear()
  state.reset()
  f.build_ok(f.builder_for(state, build_log~, deps_log~), "out")
  assert_eq(f.runner.commands_ran.length(), 1)
  assert_true(
    @moonja.Disk::stat(f.fs, "in1") <
    build_log.lookup_by_output("out").unwrap().mtime,
  )
  // Then nothing is left to do.
  f.runner.commands_ran.clear()
  state.reset()
  let builder = f.builder_for(state, build_log~, deps_log~)
  ignore(builder.add_target_name("out"))
  assert_true(builder.already_up_to_date())
}

///|
test "BuildWithDepsLogTest.TestInputMtimeRaceConditionWithDepFile" {
  let f = build_fixture()
  f.fs.create("header.h", "")
  let state = fresh_state(
    "rule long-cc\n  command = long-cc\nbuild out: long-cc\n  deps = gcc\n  depfile = out.d\n  test_dependency = header.h\n",
    cat_rule=false,
  )
  let build_log = open_build_log(f.fs)
  let deps_log = f.open_deps_log(state)
  let rebuild = fn(expect_run : Bool) raise {
    f.runner.commands_ran.clear()
    state.reset()
    let builder = f.builder_for(state, build_log~, deps_log~)
    ignore(builder.add_target_name("out"))
    if expect_run {
      let (status, _) = builder.build(f.runner)
      assert_eq(status, Success)
      assert_eq(f.runner.commands_ran.length(), 1)
    } else {
      assert_true(builder.already_up_to_date())
    }
  }
  // out is built; the command started when the clock was 1.
  rebuild(true)
  assert_eq(build_log.lookup_by_output("out").unwrap().mtime, 1)
  // header.h is newer than the recorded mtime: rebuild.
  rebuild(true)
  // It was not updated during that build: nothing to do.
  rebuild(false)
  // Touch the header.
  f.fs.create("header.h", "")
  assert_eq(f.fs.now(), 7)
  // long-cc updates header.h while it runs.
  rebuild(true)
  // header.h is in the deps log now, so the change is noticed.
  rebuild(true)
  // Not updated during that build: clean.
  rebuild(false)
}

///|
let restat_header_manifest : String =
  #|rule true
  #|  command = true
  #|  restat = 1
  #|build header.h: true header.in
  #|

///|
test "BuildTest.RestatDepfileDependency" {
  // A restat rule generating a header cancels compilations.
  let f = build_fixture()
  f.parse(restat_header_manifest + "build out: cat in1\n  depfile = in1.d\n")
  f.fs.create("header.h", "")
  f.fs.create("in1.d", "out: header.h")
  ignore(f.fs.tick())
  f.fs.create("header.in", "")
  f.add_target("out")
  assert_eq(f.build(), (Success, ""))
}

///|
test "BuildWithDepsLogTest.RestatDepfileDependencyDepsLog" {
  let f = build_fixture()
  let manifest = restat_header_manifest +
    "build out: cat in1\n  deps = gcc\n  depfile = in1.d\n"
  let state = fresh_state(manifest)
  let deps_log = f.open_deps_log(state, load=false)
  let builder = f.builder_for(state, deps_log~)
  ignore(builder.add_target_name("out"))
  f.fs.create("in1.d", "out: header.h")
  assert_eq(builder.build(f.runner), (Success, ""))
  deps_log.close(f.fs)
  // Touch the restat rule's input and build again.
  let state = fresh_state(manifest)
  ignore(f.fs.tick())
  f.fs.create("header.in", "")
  let deps_log = f.open_deps_log(state)
  f.runner.commands_ran.clear()
  f.build_ok(f.builder_for(state, deps_log~), "out")
  // true ran; out was cancelled by the restat through the header.
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildWithDepsLogTest.DepFileOKDepsLog" {
  let f = build_fixture()
  let manifest = "rule cc\n  command = cc $in\n  depfile = $out.d\n  deps = gcc\nbuild fo$ o.o: cc foo.c\n"
  f.fs.create("foo.c", "")
  let state = fresh_state(manifest, cat_rule=false)
  let deps_log = f.open_deps_log(state, load=false)
  let builder = f.builder_for(state, deps_log~)
  ignore(builder.add_target_name("fo o.o"))
  f.fs.create("fo o.o.d", "fo\\ o.o: blah.h bar.h\n")
  assert_eq(builder.build(f.runner), (Success, ""))
  deps_log.close(f.fs)
  let state = fresh_state(manifest, cat_rule=false)
  let deps_log = f.open_deps_log(state)
  let builder = f.builder_for(state, deps_log~)
  let edge = state.edges()[state.edges().length() - 1]
  state.get_node("bar.h", 0).set_dirty(true) // bar.h is missing.
  ignore(builder.add_target_name("fo o.o"))
  // The deps add no edges, but two inputs.
  assert_eq(state.edges().length(), 1)
  assert_eq(edge.inputs().length(), 3)
  assert_eq(edge.evaluate_command(), "cc foo.c")
}

///|
test "BuildWithDepsLogTest.DiscoveredDepDuringBuildChanged" {
  let f = build_fixture()
  let manifest =
    #|rule touch-out-implicit-dep
    #|  command = touch $out ; sleep 1 ; touch $test_dependency
    #|rule generate-depfile
    #|  command = touch $out ; echo "$out: $test_dependency" > $depfile
    #|build out1: touch-out-implicit-dep in1
    #|  test_dependency = inimp
    #|build out2: generate-depfile in1 || out1
    #|  test_dependency = inimp
    #|  depfile = out2.d
    #|  deps = gcc
    #|
  f.fs.create("in1", "")
  ignore(f.fs.tick())
  let build_log = @moonja.BuildLog::new()
  let run = fn(load : Bool, expect_up_to_date : Bool) raise {
    let state = fresh_state(manifest, cat_rule=false)
    let deps_log = f.open_deps_log(state, load~)
    let builder = f.builder_for(state, build_log~, deps_log~)
    ignore(builder.add_target_name("out2"))
    if expect_up_to_date {
      assert_true(builder.already_up_to_date())
    } else {
      assert_false(builder.already_up_to_date())
      assert_eq(builder.build(f.runner).0, Success)
      assert_true(builder.already_up_to_date())
    }
    deps_log.close(f.fs)
  }
  run(false, false)
  ignore(f.fs.tick())
  f.fs.create("in1", "")
  run(true, false)
  ignore(f.fs.tick())
  run(true, true)
}

///|
test "BuildWithDepsLogTest.DepFileDepsLogCanonicalize" {
  let f = build_fixture(platform=Windows)
  let manifest = "rule cc\n  command = cc $in\n  depfile = $out.d\n  deps = gcc\nbuild a/b\\c\\d/e/fo$ o.o: cc x\\y/z\\foo.c\n"
  f.fs.create("x/y/z/foo.c", "")
  let state = fresh_state(manifest, cat_rule=false, platform=Windows)
  let deps_log = f.open_deps_log(state, load=false)
  let builder = f.builder_for(state, deps_log~)
  ignore(builder.add_target_name("a/b/c/d/e/fo o.o"))
  // Different slashes from the manifest.
  f.fs.create("a/b\\c\\d/e/fo o.o.d", "a\\b\\c\\d\\e\\fo\\ o.o: blah.h bar.h\n")
  assert_eq(builder.build(f.runner), (Success, ""))
  deps_log.close(f.fs)
  let state = fresh_state(manifest, cat_rule=false, platform=Windows)
  let deps_log = f.open_deps_log(state)
  let builder = f.builder_for(state, deps_log~)
  state.get_node("bar.h", 0).set_dirty(true) // bar.h is missing.
  ignore(builder.add_target_name("a/b/c/d/e/fo o.o"))
  assert_eq(state.edges().length(), 1)
  let edge = state.edges()[0]
  assert_eq(edge.inputs().length(), 3)
  // The manifest's slashes, not the depfile's.
  assert_eq(edge.evaluate_command(), "cc x\\y/z\\foo.c")
}

///|
test "BuildTest.RestatMissingDepfile" {
  // https://github.com/ninja-build/ninja/issues/603: a restat rule does
  // not cancel an edge whose depfile is missing.
  let f = build_fixture()
  let manifest = restat_header_manifest +
    "build out: cat header.h\n  depfile = out.d\n"
  f.fs.create("header.h", "")
  ignore(f.fs.tick())
  f.fs.create("out", "")
  f.fs.create("header.in", "")
  // Only header.h would rebuild, but the missing depfile forces out too.
  f.rebuild_target("out", manifest)
  assert_eq(f.runner.commands_ran.length(), 2)
}

///|
test "BuildWithDepsLogTest.RestatMissingDepfileDepslog" {
  // The same with missing deps in the deps log.
  let f = build_fixture()
  let manifest = restat_header_manifest +
    "build out: cat header.h\n  deps = gcc\n  depfile = out.d\n"
  // A first build fills the deps log from out.d.
  f.fs.create("header.in", "")
  f.fs.create("out.d", "out: header.h")
  f.fs.create("header.h", "")
  let rebuild = fn(deps : String, expected : Int32) raise {
    f.rebuild_target("out", manifest, log_path=build_log_path, deps_path=deps)
    assert_eq(f.runner.commands_ran.length(), expected)
  }
  rebuild(deps_file_path, 2)
  rebuild(deps_file_path, 0)
  // Touch header.in and switch to a new, empty deps log: the restat of
  // header.h must not cancel out, whose deps are missing.
  ignore(f.fs.tick())
  f.fs.create("header.in", "")
  rebuild("ninja_deps2", 2)
  rebuild("ninja_deps2", 0)
  // A newer target invalidates its deps too.
  ignore(f.fs.tick())
  f.fs.create("header.in", "")
  f.fs.create("out", "")
  rebuild("ninja_deps2", 2)
  rebuild("ninja_deps2", 0)
}

///|
test "BuildTest.WrongOutputInDepfileCausesRebuild" {
  let f = build_fixture()
  let manifest = "rule cc\n  command = cc $in\n  depfile = $out.d\nbuild foo.o: cc foo.c\n"
  f.fs.create("foo.c", "")
  f.fs.create("foo.o", "")
  f.fs.create("header.h", "")
  f.fs.create("foo.o.d", "bar.o.d: header.h\n")
  f.rebuild_target(
    "foo.o",
    manifest,
    log_path=build_log_path,
    deps_path=deps_file_path,
  )
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildWithDepsLogTest.ValidationThroughDepfile" {
  let f = build_fixture()
  let manifest =
    #|build out: cat in |@ validate
    #|build validate: cat in2 | out
    #|build out2: cat in3
    #|  deps = gcc
    #|  depfile = out2.d
    #|
  f.fs.create("in", "")
  f.fs.create("in2", "")
  f.fs.create("in3", "")
  f.fs.create("out2.d", "out: out")
  let state = fresh_state(manifest)
  let deps_log = f.open_deps_log(state, load=false)
  f.build_ok(f.builder_for(state, deps_log~), "out2")
  // Only out2 runs the first time.
  assert_eq(f.runner.commands_ran, ["cat in3 > out2"])
  // The depfile was removed.
  assert_eq(@moonja.Disk::stat(f.fs, "out2.d"), 0)
  deps_log.close(f.fs)
  ignore(f.fs.tick())
  f.runner.commands_ran.clear()
  f.fs.create("in2", "")
  f.fs.create("in3", "")
  let state = fresh_state(manifest)
  let deps_log = f.open_deps_log(state)
  f.build_ok(f.builder_for(state, deps_log~), "out2")
  // out and validate run too; out first, as out2 and validate need it.
  assert_eq(f.runner.commands_ran.length(), 3)
  assert_eq(f.runner.commands_ran[0], "cat in > out")
}
