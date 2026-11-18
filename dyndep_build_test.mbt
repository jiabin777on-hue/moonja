// Ported from ninja v1.13.2 src/build_test.cc: the console pool, dyndep
// and validation build cases (Apache-2.0, see NOTICE). Test names follow
// the original.

///|
/// Builds `target` and returns the result and the commands that ran.
fn BuildFixture::build_target(
  self : BuildFixture,
  target : String,
) -> ((@moonja.ExitStatus, String), Array[String]) raise {
  self.add_target(target)
  let result = self.build()
  (result, self.runner.commands_ran.copy())
}

///|
let touch_cp : String =
  #|rule touch
  #|  command = touch $out $out.imp
  #|rule cp
  #|  command = cp $in $out
  #|

///|
let touch_plain_cp : String =
  #|rule touch
  #|  command = touch $out
  #|rule cp
  #|  command = cp $in $out
  #|

///|
test "BuildTest.Console" {
  let f = build_fixture()
  f.parse(
    "rule console\n  command = console\n  pool = console\nbuild cons: console in.txt\n",
  )
  f.fs.create("in.txt", "")
  let (result, ran) = f.build_target("cons")
  assert_eq(result, (Success, ""))
  assert_eq(ran.length(), 1)
}

///|
test "BuildTest.DyndepMissingAndNoRule" {
  // A dyndep file that is missing and has no rule to build it.
  let f = build_fixture()
  f.parse(
    "rule touch\n  command = touch $out\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  assert_eq(
    f.add_target_error("out"),
    "loading 'dd': No such file or directory",
  )
}

///|
test "BuildTest.DyndepReadyImplicitConnection" {
  // A dyndep file loaded at once shows that an implicit output of one edge
  // is an implicit input of another.
  let f = build_fixture()
  f.parse(
    "rule touch\n  command = touch $out $out.imp\nbuild tmp: touch || dd\n  dyndep = dd\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create(
    "dd", "ninja_dyndep_version = 1\nbuild out | out.imp: dyndep | tmp.imp\nbuild tmp | tmp.imp: dyndep\n",
  )
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["touch tmp tmp.imp", "touch out out.imp"])
}

///|
test "BuildTest.DyndepReadySyntaxError" {
  let f = build_fixture()
  f.parse(
    "rule touch\n  command = touch $out\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create("dd", "build out: dyndep\n")
  assert_eq(
    f.add_target_error("out"),
    "dd:1: expected 'ninja_dyndep_version = ...'\n",
  )
}

///|
test "BuildTest.DyndepReadyCircular" {
  let f = build_fixture()
  f.parse(
    "rule r\n  command = unused\nbuild out: r in || dd\n  dyndep = dd\nbuild in: r circ\n",
  )
  f.fs.create("dd", "ninja_dyndep_version = 1\nbuild out | circ: dyndep\n")
  f.fs.create("out", "")
  assert_eq(f.add_target_error("out"), "dependency cycle: circ -> in -> circ")
}

///|
test "BuildTest.DyndepBuild" {
  // A dyndep file is built and loaded, and says nothing new.
  let f = build_fixture()
  f.parse(
    touch_plain_cp +
    "build dd: cp dd-in\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create("dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep\n")
  f.add_target("out")
  let created = f.fs.files_created().length()
  assert_eq(f.build(), (Success, ""))
  assert_eq(f.runner.commands_ran, ["cp dd-in dd", "touch out"])
  assert_eq(f.fs.files_read(), ["dd-in", "dd"])
  assert_eq(f.fs.files_created().length(), created + 3)
  for path in ["dd", "out", ".ninja_lock"] {
    assert_true(f.fs.files_created().contains(path), msg=path)
  }
}

///|
test "BuildTest.DyndepBuildSyntaxError" {
  let f = build_fixture()
  f.parse(
    touch_plain_cp +
    "build dd: cp dd-in\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create("dd-in", "build out: dyndep\n")
  f.add_target("out")
  assert_eq(
    f.build(),
    (Failure, "dd:1: expected 'ninja_dyndep_version = ...'\n"),
  )
}

///|
test "BuildTest.DyndepBuildUnrelatedOutput" {
  // A dyndep file may have dependents that do not bind it.
  let f = build_fixture()
  f.parse(
    touch_plain_cp +
    "build dd: cp dd-in\nbuild unrelated: touch || dd\nbuild out: touch unrelated || dd\n  dyndep = dd\n",
  )
  f.fs.create("dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep\n")
  ignore(f.fs.tick())
  f.fs.create("out", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch unrelated", "touch out"])
}

///|
test "BuildTest.DyndepBuildDiscoverNewOutput" {
  let f = build_fixture()
  f.parse(
    touch_cp + "build dd: cp dd-in\nbuild out: touch in || dd\n  dyndep = dd\n",
  )
  f.fs.create("in", "")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out | out.imp: dyndep\n",
  )
  ignore(f.fs.tick())
  f.fs.create("out", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch out out.imp"])
}

///|
test "BuildTest.DyndepBuildDiscoverNewOutputWithMultipleRules1" {
  // The new output already has another edge.
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd: cp dd-in\nbuild out1 | out-twice.imp: touch in\nbuild out2: touch in || dd\n  dyndep = dd\n",
  )
  f.fs.create("in", "")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out2 | out-twice.imp: dyndep\n",
  )
  ignore(f.fs.tick())
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.add_target("out1")
  f.add_target("out2")
  assert_eq(f.build(), (Failure, "multiple rules generate out-twice.imp"))
}

///|
test "BuildTest.DyndepBuildDiscoverNewOutputWithMultipleRules2" {
  // The new output is also added to another edge by another dyndep file.
  let f = build_fixture()
  f.parse(
    touch_cp +
    // dd2 depends on dd1 to make the order predictable.
    "build dd1: cp dd1-in\nbuild out1: touch || dd1\n  dyndep = dd1\nbuild dd2: cp dd2-in || dd1\nbuild out2: touch || dd2\n  dyndep = dd2\n",
  )
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.fs.create(
    "dd1-in", "ninja_dyndep_version = 1\nbuild out1 | out-twice.imp: dyndep\n",
  )
  f.fs.create("dd2-in", "")
  f.fs.create(
    "dd2", "ninja_dyndep_version = 1\nbuild out2 | out-twice.imp: dyndep\n",
  )
  ignore(f.fs.tick())
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.add_target("out1")
  f.add_target("out2")
  assert_eq(f.build(), (Failure, "multiple rules generate out-twice.imp"))
}

///|
test "BuildTest.DyndepBuildDiscoverNewInput" {
  let f = build_fixture()
  f.parse(
    touch_plain_cp +
    "build dd: cp dd-in\nbuild in: touch\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create("dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep | in\n")
  ignore(f.fs.tick())
  f.fs.create("out", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch in", "touch out"])
}

///|
test "BuildTest.DyndepBuildDiscoverNewInputWithValidation" {
  // A dyndep file cannot use the |@ validation syntax.
  let f = build_fixture()
  f.parse(
    touch_plain_cp +
    "build dd: cp dd-in\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep |@ validation\n",
  )
  f.add_target("out")
  let (status, message) = f.build()
  assert_eq(status, Failure)
  let first_line = match message.find("\n") {
    Some(at) => message.unsafe_substring(start=0, end=at)
    None => message
  }
  assert_eq(first_line, "dd:2: expected newline, got '|@'")
}

///|
test "BuildTest.DyndepBuildDiscoverNewInputWithTransitiveValidation" {
  // The new input has a validation edge.
  let f = build_fixture()
  f.parse(
    touch_plain_cp +
    "build dd: cp dd-in\nbuild in: touch |@ validation\nbuild validation: touch in out\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create("dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep | in\n")
  ignore(f.fs.tick())
  f.fs.create("out", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch in", "touch out", "touch validation"])
}

///|
test "BuildTest.DyndepBuildDiscoverImplicitConnection" {
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd: cp dd-in\nbuild tmp: touch || dd\n  dyndep = dd\nbuild out: touch || dd\n  dyndep = dd\n",
  )
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out | out.imp: dyndep | tmp.imp\nbuild tmp | tmp.imp: dyndep\n",
  )
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch tmp tmp.imp", "touch out out.imp"])
}

///|
test "BuildTest.DyndepBuildDiscoverOutputAndDepfileInput" {
  // An implicit output from a dyndep file is also a depfile input of
  // another edge.
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd: cp dd-in\nbuild tmp: touch || dd\n  dyndep = dd\nbuild out: cp tmp\n  depfile = out.d\n",
  )
  f.fs.create("out.d", "out: tmp.imp\n")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild tmp | tmp.imp: dyndep\n",
  )
  f.add_target("out")
  // The depfile did not give tmp.imp a phony in-edge.
  assert_true(f.node("tmp.imp").in_edge() is None)
  assert_eq(f.build(), (Success, ""))
  // The dyndep file gave it a real one.
  assert_false(f.node("tmp.imp").in_edge().unwrap().is_phony())
  assert_eq(f.runner.commands_ran, [
    "cp dd-in dd", "touch tmp tmp.imp", "cp tmp out",
  ])
  assert_true(f.fs.files_created().contains("tmp.imp"))
  assert_true(f.builder.already_up_to_date())
}

///|
test "BuildTest.DyndepBuildDiscoverNowWantEdge" {
  // A missing implicit output from the dyndep file makes an edge wanted.
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd: cp dd-in\nbuild tmp: touch || dd\n  dyndep = dd\nbuild out: touch tmp || dd\n  dyndep = dd\n",
  )
  f.fs.create("tmp", "")
  f.fs.create("out", "")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out: dyndep\nbuild tmp | tmp.imp: dyndep\n",
  )
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch tmp tmp.imp", "touch out out.imp"])
}

///|
test "BuildTest.DyndepBuildDiscoverNowWantEdgeAndDependent" {
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd: cp dd-in\nbuild tmp: touch || dd\n  dyndep = dd\nbuild out: touch tmp\n",
  )
  f.fs.create("tmp", "")
  f.fs.create("out", "")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild tmp | tmp.imp: dyndep\n",
  )
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "touch tmp tmp.imp", "touch out out.imp"])
}

///|
test "BuildTest.DyndepBuildDiscoverCircular" {
  let f = build_fixture()
  f.parse(
    "rule r\n  command = unused\nrule cp\n  command = cp $in $out\nbuild dd: cp dd-in\nbuild out: r in || dd\n  depfile = out.d\n  dyndep = dd\nbuild in: r || dd\n  dyndep = dd\n",
  )
  f.fs.create("out.d", "out: inimp\n")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out | circ: dyndep\nbuild in: dyndep | circ\n",
  )
  f.fs.create("out", "")
  f.add_target("out")
  let (status, message) = f.build()
  assert_eq(status, Failure)
  // The cycle may be found from either end.
  assert_true(
    message == "dependency cycle: circ -> in -> circ" ||
    message == "dependency cycle: in -> circ -> in",
    msg=message,
  )
}

///|
test "BuildWithLogTest.DyndepBuildDiscoverRestat" {
  // The dyndep file adds a restat binding.
  let (f, _) = build_with_log()
  f.parse(
    "rule true\n  command = true\nrule cp\n  command = cp $in $out\nbuild dd: cp dd-in\nbuild out1: true in || dd\n  dyndep = dd\nbuild out2: cat out1\n",
  )
  f.fs.create("out1", "")
  f.fs.create("out2", "")
  f.fs.create(
    "dd-in", "ninja_dyndep_version = 1\nbuild out1: dyndep\n  restat = 1\n",
  )
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // A first build fills the log.
  let (result, ran) = f.build_target("out2")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd-in dd", "true", "cat out1 > out2"])
  f.again()
  ignore(f.fs.tick())
  f.fs.create("in", "")
  // out1 rebuilds, but true leaves it alone, so out2 is cancelled.
  let (result, ran) = f.build_target("out2")
  assert_eq(result.0, Success)
  assert_eq(ran, ["true"])
}

///|
test "BuildTest.DyndepBuildDiscoverScheduledEdge" {
  // The dyndep file adds an input made by an edge that is already running;
  // the edge must not be scheduled again.
  let f = build_fixture()
  f.parse(
    touch_cp +
    // zdd finishes while out1 is still active.
    "build out1 | out1.imp: touch\nbuild zdd: cp zdd-in\n  verify_active_edge = out1\nbuild out2: cp out1 || zdd\n  dyndep = zdd\n",
  )
  f.fs.create(
    "zdd-in", "ninja_dyndep_version = 1\nbuild out2: dyndep | out1.imp\n",
  )
  // Run out1 and zdd concurrently; the fake runner finishes zdd first.
  f.runner.max_active_edges = 2
  f.add_target("out1")
  f.add_target("out2")
  assert_eq(f.build(), (Success, ""))
  let ran = f.runner.commands_ran
  assert_eq(ran.length(), 3)
  assert_true(
    (ran[0] == "touch out1 out1.imp" && ran[1] == "cp zdd-in zdd") ||
    (ran[1] == "touch out1 out1.imp" && ran[0] == "cp zdd-in zdd"),
  )
  assert_eq(ran[2], "cp out1 out2")
}

///|
test "BuildTest.DyndepTwoLevelDirect" {
  // A clean dyndep file depending on a dirty one loads after it.
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd1: cp dd1-in\nbuild out1 | out1.imp: touch || dd1\n  dyndep = dd1\nbuild dd2: cp dd2-in || dd1\nbuild out2: touch || dd2\n  dyndep = dd2\n",
  )
  f.fs.create("out1.imp", "")
  f.fs.create("out2", "")
  f.fs.create("out2.imp", "")
  f.fs.create("dd1-in", "ninja_dyndep_version = 1\nbuild out1: dyndep\n")
  f.fs.create("dd2-in", "")
  f.fs.create(
    "dd2", "ninja_dyndep_version = 1\nbuild out2 | out2.imp: dyndep | out1.imp\n",
  )
  let (result, ran) = f.build_target("out2")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd1-in dd1", "touch out1 out1.imp", "touch out2 out2.imp"])
}

///|
test "BuildTest.DyndepTwoLevelIndirect" {
  // Inputs added by one dyndep file are outputs added by another.
  let f = build_fixture()
  f.parse(
    touch_cp +
    "build dd1: cp dd1-in\nbuild out1: touch || dd1\n  dyndep = dd1\nbuild dd2: cp dd2-in || out1\nbuild out2: touch || dd2\n  dyndep = dd2\n",
  )
  f.fs.create("out1.imp", "")
  f.fs.create("out2", "")
  f.fs.create("out2.imp", "")
  f.fs.create(
    "dd1-in", "ninja_dyndep_version = 1\nbuild out1 | out1.imp: dyndep\n",
  )
  f.fs.create("dd2-in", "")
  f.fs.create(
    "dd2", "ninja_dyndep_version = 1\nbuild out2 | out2.imp: dyndep | out1.imp\n",
  )
  let (result, ran) = f.build_target("out2")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd1-in dd1", "touch out1 out1.imp", "touch out2 out2.imp"])
}

///|
let two_level_discovered : String =
  #|build dd0: cp dd0-in
  #|build dd1: cp dd1-in
  #|build in: touch
  #|build tmp: touch || dd0
  #|  dyndep = dd0
  #|build out: touch || dd1
  #|  dyndep = dd1
  #|

///|
test "BuildTest.DyndepTwoLevelDiscoveredReady" {
  // A discovered input whose edge has a dyndep file ready to load.
  let f = build_fixture()
  f.parse(touch_plain_cp + two_level_discovered)
  f.fs.create("dd1-in", "ninja_dyndep_version = 1\nbuild out: dyndep | tmp\n")
  f.fs.create("dd0-in", "")
  f.fs.create("dd0", "ninja_dyndep_version = 1\nbuild tmp: dyndep | in\n")
  ignore(f.fs.tick())
  f.fs.create("out", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cp dd1-in dd1", "touch in", "touch tmp", "touch out"])
}

///|
test "BuildTest.DyndepTwoLevelDiscoveredDirty" {
  // A discovered input whose edge has a dyndep file to build.
  let f = build_fixture()
  f.parse(touch_plain_cp + two_level_discovered)
  f.fs.create("dd1-in", "ninja_dyndep_version = 1\nbuild out: dyndep | tmp\n")
  f.fs.create("dd0-in", "ninja_dyndep_version = 1\nbuild tmp: dyndep | in\n")
  ignore(f.fs.tick())
  f.fs.create("out", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, [
    "cp dd1-in dd1", "cp dd0-in dd0", "touch in", "touch tmp", "touch out",
  ])
}

///|
test "BuildTest.Validation" {
  let f = build_fixture()
  f.parse("build out: cat in |@ validate\nbuild validate: cat in2\n")
  f.fs.create("in", "")
  f.fs.create("in2", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran.length(), 2)
  // Touching in rebuilds only out.
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.again()
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cat in > out"])
  // Touching in2 rebuilds only validate.
  ignore(f.fs.tick())
  f.fs.create("in2", "")
  f.again()
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cat in2 > validate"])
}

///|
test "BuildTest.ValidationDependsOnOutput" {
  let f = build_fixture()
  f.parse("build out: cat in |@ validate\nbuild validate: cat in2 | out\n")
  f.fs.create("in", "")
  f.fs.create("in2", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran.length(), 2)
  // Touching in rebuilds out and validate.
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.again()
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran.length(), 2)
  // Touching in2 rebuilds only validate.
  ignore(f.fs.tick())
  f.fs.create("in2", "")
  f.again()
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cat in2 > validate"])
}

///|
test "BuildTest.ValidationCircular" {
  let f = build_fixture()
  f.parse("build out: cat in |@ out2\nbuild out2: cat in2 |@ out\n")
  f.fs.create("in", "")
  f.fs.create("in2", "")
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran.length(), 2)
  ignore(f.fs.tick())
  f.fs.create("in", "")
  f.again()
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cat in > out"])
  ignore(f.fs.tick())
  f.fs.create("in2", "")
  f.again()
  let (result, ran) = f.build_target("out")
  assert_eq(result, (Success, ""))
  assert_eq(ran, ["cat in2 > out2"])
}

///|
test "BuildTest.ValidationWithCircularDependency" {
  let f = build_fixture()
  f.parse(
    "build out: cat in |@ validate\nbuild validate: cat validate_in | out\nbuild validate_in: cat validate\n",
  )
  f.fs.create("in", "")
  assert_eq(
    f.add_target_error("out"),
    "dependency cycle: validate -> validate_in -> validate",
  )
}
