// Ported from ninja v1.13.2 src/build_test.cc, the BuildTest cases
// (Apache-2.0, see NOTICE). Test names follow the original.

///|
/// ninja's FakeCommandRunner: "runs" commands by rule name against the
/// in-memory disk.
struct FakeRunner {
  fs : @moonja.MemoryDisk
  commands_ran : Array[String]
  active_edges : Array[@moonja.Edge]
  max_active_edges : Int32
  /// Failures found inside wait_for_command, checked by the tests.
  errors : Array[String]
}

///|
fn FakeRunner::new(fs : @moonja.MemoryDisk) -> FakeRunner {
  { fs, commands_ran: [], active_edges: [], max_active_edges: 1, errors: [], }
}

///|
fn binding(edge : @moonja.Edge, key : String) -> String {
  edge.get_binding(key) catch {
    _ => ""
  }
}

///|
fn touch_outputs(fs : @moonja.MemoryDisk, edge : @moonja.Edge) -> Unit {
  for out in edge.outputs() {
    fs.create(out.path(), "")
  }
}

///|
impl @moonja.CommandRunner for FakeRunner with fn can_run_more(self) {
  if self.active_edges.length() < self.max_active_edges {
    2147483647
  } else {
    0
  }
}

///|
impl @moonja.CommandRunner for FakeRunner with fn start_command(self, edge) {
  self.commands_ran.push(edge.evaluate_command() catch { _ => "" })
  let fs = self.fs
  match edge.rule().name() {
    "cat"
    | "cat_rsp"
    | "cat_rsp_out"
    | "cc"
    | "cp_multi_msvc"
    | "cp_multi_gcc"
    | "touch"
    | "touch-interrupt"
    | "touch-fail-tick2" => touch_outputs(fs, edge)
    "true" | "fail" | "interrupt" | "console" => ()
    "cp" =>
      match fs.contents(edge.inputs()[0].path()) {
        Some(content) => fs.create(edge.outputs()[0].path(), content)
        None => ()
      }
    "touch-implicit-dep-out" => {
      let dep = binding(edge, "test_dependency")
      ignore(fs.tick())
      fs.create(dep, "")
      ignore(fs.tick())
      touch_outputs(fs, edge)
    }
    "touch-out-implicit-dep" => {
      let dep = binding(edge, "test_dependency")
      touch_outputs(fs, edge)
      ignore(fs.tick())
      fs.create(dep, "")
    }
    "generate-depfile" => {
      let dep = binding(edge, "test_dependency")
      let touch_dep = binding(edge, "touch_dependency") != ""
      let depfile = edge.get_unescaped_depfile() catch { _ => "" }
      if touch_dep {
        ignore(fs.tick())
        fs.create(dep, "")
      }
      let contents = StringBuilder()
      for out in edge.outputs() {
        contents.write_string(out.path() + ": " + dep + "\n")
        fs.create(out.path(), "")
      }
      fs.create(depfile, contents.to_string())
    }
    "long-cc" => {
      let dep = binding(edge, "test_dependency")
      let depfile = edge.get_unescaped_depfile() catch { _ => "" }
      let contents = StringBuilder()
      for out in edge.outputs() {
        ignore(fs.tick())
        ignore(fs.tick())
        ignore(fs.tick())
        fs.create(out.path(), "")
        contents.write_string(out.path() + ": " + dep + "\n")
      }
      if dep != "" && depfile != "" {
        fs.create(depfile, contents.to_string())
      }
    }
    _ => {
      self.errors.push("unknown command")
      return false
    }
  }
  self.active_edges.push(edge)
  // Tests control the order by the name of the first output.
  self.active_edges.sort_by(fn(a, b) {
    lex_compare(a.outputs()[0].path(), b.outputs()[0].path())
  })
  true
}

///|
impl @moonja.CommandRunner for FakeRunner with fn active_edges(self) {
  self.active_edges.copy()
}

///|
impl @moonja.CommandRunner for FakeRunner with fn abort(self) {
  self.active_edges.clear()
}

///|
impl @moonja.WaitingCommandRunner for FakeRunner with fn wait_for_command(self) {
  guard self.active_edges.length() > 0 else { return None }
  // Everything finished when it started; take the last edge.
  let index = self.active_edges.length() - 1
  let edge = self.active_edges[index]
  let name = edge.rule().name()
  if name == "interrupt" || name == "touch-interrupt" {
    return Some(@moonja.CommandResult::new(edge, Interrupted))
  }
  if name == "console" {
    ignore(self.active_edges.remove(index))
    return Some(
      @moonja.CommandResult::new(
        edge,
        if edge.use_console() {
          Success
        } else {
          Failure
        },
      ),
    )
  }
  let output = StringBuilder()
  if name == "cp_multi_msvc" {
    let prefix = binding(edge, "msvc_deps_prefix")
    for input in edge.inputs() {
      output.write_string(prefix + input.path() + "\n")
    }
  }
  let status : @moonja.ExitStatus = if name == "fail" ||
    (name == "touch-fail-tick2" && self.fs.now() == 2) {
    Failure
  } else {
    Success
  }
  // Simulates another process changing files while the command runs; only
  // on the first and third run of the rule.
  if name == "long-cc" {
    let dep = binding(edge, "test_dependency")
    if self.fs.now() == 4 {
      self.fs.set_mtime(dep, 3)
    }
    if self.fs.now() == 10 {
      self.fs.set_mtime(dep, 9)
    }
  }
  // Lets tests check that another edge is still running.
  let verify = binding(edge, "verify_active_edge")
  if verify != "" &&
    !self.active_edges
    .iter()
    .any(fn(e) { e.outputs().length() > 0 && e.outputs()[0].path() == verify }) {
    self.errors.push("verify_active_edge \{verify} not active")
  }
  ignore(self.active_edges.remove(index))
  Some(@moonja.CommandResult::new(edge, status, output=output.to_string()))
}

///|
/// BuildTest's fixture.
struct BuildFixture {
  state : @moonja.State
  fs : @moonja.MemoryDisk
  runner : FakeRunner
  config : @moonja.BuildConfig
  builder : @moonja.Builder
}

///|
fn quiet_config() -> @moonja.BuildConfig {
  let config = @moonja.BuildConfig::default()
  config.verbosity = Quiet
  config
}

///|
fn build_fixture(
  deps_log? : @moonja.DepsLog,
  platform~ : @moonja.Platform = Posix,
) -> BuildFixture raise {
  let state = @moonja.State::new(platform~)
  let parser = @moonja.ManifestParser::without_files(state)
  parser.parse_test("rule cat\n  command = cat $in > $out\n")
  parser.parse_test(
    "build cat1: cat in1\nbuild cat2: cat in1 in2\nbuild cat12: cat cat1 cat2\n",
  )
  let fs = @moonja.MemoryDisk::new()
  fs.create("in1", "")
  fs.create("in2", "")
  let config = quiet_config()
  {
    state,
    fs,
    runner: FakeRunner::new(fs),
    config,
    builder: @moonja.Builder::new(state, config, fs, deps_log?),
  }
}

///|
fn BuildFixture::parse(self : BuildFixture, input : String) -> Unit raise {
  @moonja.ManifestParser::without_files(self.state).parse_test(input)
}

///|
fn BuildFixture::node(self : BuildFixture, path : String) -> @moonja.Node {
  self.state.get_node(path, 0)
}

///|
/// Marks a path dirty; an input file is also stat'ed as missing.
fn BuildFixture::dirty(self : BuildFixture, path : String) -> Unit {
  let node = self.node(path)
  node.set_dirty(true)
  if node.in_edge() is None {
    node.mark_missing()
  }
}

///|
fn BuildFixture::add_target(self : BuildFixture, name : String) -> Unit raise {
  ignore(self.builder.add_target_name(name))
}

///|
fn BuildFixture::add_target_error(self : BuildFixture, name : String) -> String {
  try {
    ignore(self.builder.add_target_name(name))
    ""
  } catch {
    error => error.message()
  }
}

///|
fn BuildFixture::build(
  self : BuildFixture,
) -> (@moonja.ExitStatus, String) raise {
  let result = self.builder.build(self.runner)
  assert_eq(self.runner.errors, [])
  result
}

///|
/// Resets the state and clears the commands for another build.
fn BuildFixture::again(self : BuildFixture) -> Unit {
  self.state.reset()
  self.runner.commands_ran.clear()
}

///|
fn BuildFixture::remove(self : BuildFixture, path : String) -> Unit {
  ignore(@moonja.Disk::remove_file(self.fs, path))
}

///|
/// RebuildTarget: builds `target` of `manifest` in a fresh state (or the
/// given one) on the same disk, with optional logs.
fn BuildFixture::rebuild_target(
  self : BuildFixture,
  target : String,
  manifest : String,
  log_path? : String,
  deps_path? : String,
  state~ : @moonja.State = @moonja.State::new(),
) -> Unit raise {
  let parser = @moonja.ManifestParser::without_files(state)
  parser.parse_test("rule cat\n  command = cat $in > $out\n")
  parser.parse_test(manifest)
  let build_log = match log_path {
    Some(path) => {
      let log = @moonja.BuildLog::new()
      ignore(log.load(self.fs, path))
      log.open_for_write(self.fs, path, fn(_) { false })
      Some(log)
    }
    None => None
  }
  let deps_log = match deps_path {
    Some(path) => {
      let log = @moonja.DepsLog::new()
      ignore(log.load(self.fs, path, state))
      log.open_for_write(self.fs, path)
      Some(log)
    }
    None => None
  }
  let builder = @moonja.Builder::new(
    state,
    self.config,
    self.fs,
    build_log?,
    deps_log?,
  )
  ignore(builder.add_target_name(target))
  self.runner.commands_ran.clear()
  if !builder.already_up_to_date() {
    let (status, _) = builder.build(self.runner)
    assert_eq(status, Success)
  }
}

///|
test "BuildTest.NoWork" {
  let f = build_fixture()
  assert_true(f.builder.already_up_to_date())
}

///|
test "BuildTest.OneStep" {
  // A dirty target with one ready input is rebuilt.
  let f = build_fixture()
  f.dirty("cat1")
  f.add_target("cat1")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["cat in1 > cat1"])
}

///|
test "BuildTest.OneStep2" {
  // A target with one dirty input is rebuilt.
  let f = build_fixture()
  f.dirty("cat1")
  f.add_target("cat1")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["cat in1 > cat1"])
}

///|
test "BuildTest.TwoStep" {
  let f = build_fixture()
  f.add_target("cat12")
  assert_eq(f.build(), (Success, ""))
  let ran = f.runner.commands_ran
  assert_eq(ran.length(), 3)
  // The first two may run in either order.
  assert_true(
    (ran[0] == "cat in1 > cat1" && ran[1] == "cat in1 in2 > cat2") ||
    (ran[1] == "cat in1 > cat1" && ran[0] == "cat in1 in2 > cat2"),
  )
  assert_eq(ran[2], "cat cat1 cat2 > cat12")
  ignore(f.fs.tick())
  // Changing in2 rebuilds one intermediate file and the final one.
  f.fs.create("in2", "")
  f.state.reset()
  f.add_target("cat12")
  assert_eq(f.build(), (Success, ""))
  assert_eq(ran.length(), 5)
  assert_eq(ran[3], "cat in1 in2 > cat2")
  assert_eq(ran[4], "cat cat1 cat2 > cat12")
}

///|
test "BuildTest.TwoOutputs" {
  let f = build_fixture()
  f.parse("rule touch\n  command = touch $out\nbuild out1 out2: touch in.txt\n")
  f.fs.create("in.txt", "")
  f.add_target("out1")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["touch out1 out2"])
}

///|
test "BuildTest.ImplicitOutput" {
  let f = build_fixture()
  f.parse(
    "rule touch\n  command = touch $out $out.imp\nbuild out | out.imp: touch in.txt\n",
  )
  f.fs.create("in.txt", "")
  f.add_target("out.imp")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["touch out out.imp"])
}

///|
test "BuildTest.MultiOutIn" {
  // https://github.com/ninja-build/ninja/issues/148
  let f = build_fixture()
  f.parse(
    "rule touch\n  command = touch $out\nbuild in1 otherfile: touch in\nbuild out: touch in | in1\n",
  )
  f.fs.create("in", "")
  ignore(f.fs.tick())
  f.fs.create("in1", "")
  f.add_target("out")
  assert_eq(f.build(), (Success, ""))
}

///|
test "BuildTest.Chain" {
  let f = build_fixture()
  f.parse(
    "build c2: cat c1\nbuild c3: cat c2\nbuild c4: cat c3\nbuild c5: cat c4\n",
  )
  f.fs.create("c1", "")
  f.add_target("c5")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 4)
  f.again()
  f.add_target("c5")
  assert_true(f.builder.already_up_to_date())
  ignore(f.fs.tick())
  f.fs.create("c3", "")
  f.again()
  f.add_target("c5")
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build(), (Success, ""))
  // 3->4, 4->5
  assert_eq(f.runner.commands_ran.length(), 2)
}

///|
test "BuildTest.MissingInput" {
  // The manifest names the input, but no rule makes it.
  let f = build_fixture()
  f.dirty("in1")
  assert_eq(
    f.add_target_error("cat1"),
    "'in1', needed by 'cat1', missing and no known rule to make it",
  )
}

///|
test "BuildTest.MissingTarget" {
  let f = build_fixture()
  assert_eq(f.add_target_error("meow"), "unknown target: 'meow'")
}

///|
test "BuildTest.MissingInputTarget" {
  // The target is a missing input file.
  let f = build_fixture()
  f.dirty("in1")
  assert_eq(
    f.add_target_error("in1"),
    "'in1' missing and no known rule to make it",
  )
}

///|
test "BuildTest.MakeDirs" {
  for platform in [@moonja.Platform::Posix, Windows] {
    let f = build_fixture(platform~)
    f.parse(
      if platform is Windows {
        "build subdir\\dir2\\file: cat in1\n"
      } else {
        "build subdir/dir2/file: cat in1\n"
      },
    )
    f.add_target("subdir/dir2/file")
    assert_eq(f.build(), (Success, ""))
    assert_eq(f.fs.directories_made(), ["subdir", "subdir/dir2"])
  }
}

///|
let cc_depfile : String = "rule cc\n  command = cc $in\n  depfile = $out.d\n"

///|
test "BuildTest.DepFileMissing" {
  let f = build_fixture()
  f.parse(cc_depfile + "build fo$ o.o: cc foo.c\n")
  f.fs.create("foo.c", "")
  f.add_target("fo o.o")
  assert_eq(f.fs.files_read(), ["fo o.o.d"])
}

///|
test "BuildTest.DepFileOK" {
  let f = build_fixture()
  let orig_edges = f.state.edges().length()
  f.parse(cc_depfile + "build foo.o: cc foo.c\n")
  let edge = f.state.edges()[f.state.edges().length() - 1]
  f.fs.create("foo.c", "")
  f.node("bar.h").set_dirty(true) // bar.h is missing.
  f.fs.create("foo.o.d", "foo.o: blah.h bar.h\n")
  f.add_target("foo.o")
  assert_eq(f.fs.files_read(), ["foo.o.d"])
  // One new edge; the depfile adds nodes but no phony edges.
  assert_eq(f.state.edges().length(), orig_edges + 1)
  let generated = fn(path : String) {
    f.state.lookup_node(path).unwrap().generated_by_dep_loader()
  }
  assert_false(generated("foo.o"))
  assert_false(generated("foo.c"))
  assert_true(generated("blah.h"))
  assert_true(generated("bar.h"))
  // foo.c and two headers.
  assert_eq(edge.inputs().length(), 3)
  // The command uses only the original input.
  assert_eq(edge.evaluate_command(), "cc foo.c")
}

///|
test "BuildTest.DepFileParseError" {
  let f = build_fixture()
  f.parse(cc_depfile + "build foo.o: cc foo.c\n")
  f.fs.create("foo.c", "")
  f.fs.create("foo.o.d", "randomtext\n")
  assert_eq(f.add_target_error("foo.o"), "foo.o.d: expected ':' in depfile")
}

///|
test "BuildTest.EncounterReadyTwice" {
  let f = build_fixture()
  f.parse(
    "rule touch\n  command = touch $out\nbuild c: touch\nbuild b: touch || c\nbuild a: touch | b || c\n",
  )
  let c_out = f.node("c").out_edges()
  assert_eq(c_out.map(fn(e) { e.outputs()[0].path() }), ["b", "a"])
  f.fs.create("b", "")
  f.add_target("a")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 2)
}

///|
test "BuildTest.OrderOnlyDeps" {
  let f = build_fixture()
  f.parse(cc_depfile + "build foo.o: cc foo.c || otherfile\n")
  let edge = f.state.edges()[f.state.edges().length() - 1]
  f.fs.create("foo.c", "")
  f.fs.create("otherfile", "")
  f.fs.create("foo.o.d", "foo.o: blah.h bar.h\n")
  f.add_target("foo.o")
  // One explicit, two implicit, one order-only, in that order.
  assert_eq(edge.inputs().map(fn(n) { n.path() }), [
    "foo.c", "blah.h", "bar.h", "otherfile",
  ])
  assert_eq((edge.implicit_deps(), edge.order_only_deps()), (2, 1))
  assert_eq(edge.evaluate_command(), "cc foo.c")
  // A dirty explicit dep: rebuild.
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
  ignore(f.fs.tick())
  // The build deleted the depfile; recreate it.
  f.fs.create("foo.o.d", "foo.o: blah.h bar.h\n")
  // A dirty implicit dep: rebuild.
  f.fs.create("blah.h", "")
  f.fs.create("bar.h", "")
  f.again()
  f.add_target("foo.o")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
  ignore(f.fs.tick())
  f.fs.create("foo.o.d", "foo.o: blah.h bar.h\n")
  // A dirty order-only dep: no rebuild.
  f.fs.create("otherfile", "")
  f.again()
  f.add_target("foo.o")
  assert_true(f.builder.already_up_to_date())
  // A missing implicit dep: rebuild.
  f.remove("bar.h")
  f.again()
  f.add_target("foo.o")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildTest.RebuildOrderOnlyDeps" {
  let f = build_fixture()
  f.parse(
    "rule cc\n  command = cc $in\nrule true\n  command = true\nbuild oo.h: cc oo.h.in\nbuild foo.o: cc foo.c || oo.h\n",
  )
  f.fs.create("foo.c", "")
  f.fs.create("oo.h.in", "")
  // foo.o and its order-only dep are dirty: build both.
  f.add_target("foo.o")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 2)
  // All clean.
  f.again()
  f.add_target("foo.o")
  assert_true(f.builder.already_up_to_date())
  // The order-only dep is missing: build only it.
  f.remove("oo.h")
  f.again()
  f.add_target("foo.o")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["cc oo.h.in"])
  ignore(f.fs.tick())
  // The order-only dep is dirty: build only it.
  f.fs.create("oo.h.in", "")
  f.again()
  f.add_target("foo.o")
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["cc oo.h.in"])
}

///|
test "BuildTest.DepFileCanonicalize" {
  let f = build_fixture(platform=Windows)
  let orig_edges = f.state.edges().length()
  f.parse(cc_depfile + "build gen/stuff\\things/foo.o: cc x\\y/z\\foo.c\n")
  f.fs.create("x/y/z/foo.c", "")
  f.node("bar.h").set_dirty(true) // bar.h is missing.
  // Different slashes from the manifest.
  f.fs.create(
    "gen/stuff\\things/foo.o.d", "gen\\stuff\\things\\foo.o: blah.h bar.h\n",
  )
  f.add_target("gen/stuff/things/foo.o")
  // The depfile path is not canonicalized.
  assert_eq(f.fs.files_read(), ["gen/stuff\\things/foo.o.d"])
  assert_eq(f.state.edges().length(), orig_edges + 1)
  let edge = f.state.edges()[f.state.edges().length() - 1]
  assert_eq(edge.inputs().length(), 3)
  // The command keeps the manifest's slashes.
  assert_eq(edge.evaluate_command(), "cc x\\y/z\\foo.c")
}

///|
test "BuildTest.Phony" {
  let f = build_fixture()
  f.parse("build out: cat bar.cc\nbuild all: phony out\n")
  f.fs.create("bar.cc", "")
  f.add_target("all")
  // One command: phony runs none.
  assert_false(f.builder.already_up_to_date())
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildTest.PhonyNoWork" {
  let f = build_fixture()
  f.parse("build out: cat bar.cc\nbuild all: phony out\n")
  f.fs.create("bar.cc", "")
  f.fs.create("out", "")
  f.add_target("all")
  assert_true(f.builder.already_up_to_date())
}

///|
test "BuildTest.PhonySelfReference" {
  // Tolerated for CMake 2.8.12.x and 3.0.x, like ninja 1.7 and below.
  let f = build_fixture()
  f.parse("build a: phony a\n")
  f.add_target("a")
  assert_true(f.builder.already_up_to_date())
}

///|
/// The six cases of phony rules (see build_test.cc): with inputs, the
/// phony output is clean and takes the newest input mtime; without inputs
/// (cases 2 and 5) it is dirty and its dependents always rebuild.
fn phony_use_case(i : Int32) -> Unit raise {
  let f = build_fixture()
  f.parse(
    (
      #|rule touch
      #| command = touch $out
      #|build notreal: phony blank
      #|build phony1: phony notreal
      #|build phony2: phony
      #|build phony3: phony blank
      #|build phony4: phony notreal
      #|build phony5: phony
      #|build phony6: phony blank
      #|
      #|build test1: touch phony1
      #|build test2: touch phony2
      #|build test3: touch phony3
      #|build test4: touch phony4
      #|build test5: touch phony5
      #|build test6: touch phony6
      #|
    ),
  )
  f.fs.create("blank", "") // A real file.
  for n in 1..<=6 {
    f.add_target("test\{n}")
  }
  assert_eq(f.build(), (Success, ""))
  if i != 2 && i != 5 {
    let test_node = f.node("test\{i}")
    let phony_node = f.node("phony\{i}")
    let input_node = f.node("blank")
    f.state.reset()
    let start_time = f.fs.now()
    // Build number 1.
    f.add_target("test\{i}")
    if !f.builder.already_up_to_date() {
      assert_eq(f.build(), (Success, ""))
    }
    // Touch the input.
    f.again()
    ignore(f.fs.tick())
    f.fs.create("blank", "")
    f.add_target("test\{i}")
    // testN rebuilds and phonyN takes the new mtime.
    assert_false(f.builder.already_up_to_date())
    assert_eq(f.build(), (Success, ""))
    assert_eq(f.runner.commands_ran, ["touch test\{i}"])
    assert_true(f.builder.already_up_to_date())
    let input_time = input_node.mtime()
    assert_false(phony_node.exists())
    assert_false(phony_node.dirty())
    assert_true(phony_node.mtime() > start_time)
    assert_eq(phony_node.mtime(), input_time)
    test_node.stat(f.fs)
    assert_true(test_node.exists())
    assert_true(test_node.mtime() > start_time)
  } else {
    // The dependents always rebuild.
    f.again()
    ignore(f.fs.tick())
    f.add_target("test\{i}")
    assert_false(f.builder.already_up_to_date())
    assert_eq(f.build(), (Success, ""))
    assert_eq(f.runner.commands_ran, ["touch test\{i}"])
    f.again()
    f.add_target("test\{i}")
    assert_false(f.builder.already_up_to_date())
    assert_eq(f.build(), (Success, ""))
    assert_eq(f.runner.commands_ran, ["touch test\{i}"])
  }
}

///|
test "BuildTest.PhonyUseCase1" {
  phony_use_case(1)
}

///|
test "BuildTest.PhonyUseCase2" {
  phony_use_case(2)
}

///|
test "BuildTest.PhonyUseCase3" {
  phony_use_case(3)
}

///|
test "BuildTest.PhonyUseCase4" {
  phony_use_case(4)
}

///|
test "BuildTest.PhonyUseCase5" {
  phony_use_case(5)
}

///|
test "BuildTest.PhonyUseCase6" {
  phony_use_case(6)
}

///|
test "BuildTest.Fail" {
  let f = build_fixture()
  f.parse("rule fail\n  command = fail\nbuild out1: fail\n")
  f.add_target("out1")
  assert_eq(f.build(), (Failure, "subcommand failed"))
  assert_eq(f.runner.commands_ran.length(), 1)
}

///|
test "BuildTest.SwallowFailures" {
  let f = build_fixture()
  f.parse(
    "rule fail\n  command = fail\nbuild out1: fail\nbuild out2: fail\nbuild out3: fail\nbuild all: phony out1 out2 out3\n",
  )
  // Swallow two failures, stop at the third.
  f.config.failures_allowed = 3
  f.add_target("all")
  assert_eq(f.build(), (Failure, "subcommands failed"))
  assert_eq(f.runner.commands_ran.length(), 3)
}

///|
test "BuildTest.SwallowFailuresLimit" {
  let f = build_fixture()
  f.parse(
    "rule fail\n  command = fail\nbuild out1: fail\nbuild out2: fail\nbuild out3: fail\nbuild final: cat out1 out2 out3\n",
  )
  // Swallow ten failures; final cannot be built.
  f.config.failures_allowed = 11
  f.add_target("final")
  assert_eq(f.build(), (Failure, "cannot make progress due to previous errors"))
  assert_eq(f.runner.commands_ran.length(), 3)
}

///|
test "BuildTest.SwallowFailuresPool" {
  let f = build_fixture()
  f.parse(
    "pool failpool\n  depth = 1\nrule fail\n  command = fail\n  pool = failpool\nbuild out1: fail\nbuild out2: fail\nbuild out3: fail\nbuild final: cat out1 out2 out3\n",
  )
  f.config.failures_allowed = 11
  f.add_target("final")
  assert_eq(f.build(), (Failure, "cannot make progress due to previous errors"))
  assert_eq(f.runner.commands_ran.length(), 3)
}

///|
test "BuildTest.PoolEdgesReadyButNotWanted" {
  let f = build_fixture()
  f.fs.create("x", "")
  let manifest =
    #|pool some_pool
    #|  depth = 4
    #|rule touch
    #|  command = touch $out
    #|  pool = some_pool
    #|rule cc
    #|  command = touch grit
    #|
    #|build B.d.stamp: cc | x
    #|build C.stamp: touch B.d.stamp
    #|build final.stamp: touch || C.stamp
    #|
  f.rebuild_target("final.stamp", manifest)
  f.remove("B.d.stamp")
  let save_state = @moonja.State::new()
  f.rebuild_target("final.stamp", manifest, state=save_state)
  assert_true(save_state.lookup_pool("some_pool").unwrap().current_use() >= 0)
}
