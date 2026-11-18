// Ported from ninja v1.13.2 src/dyndep_parser_test.cc (Apache-2.0, see
// NOTICE). Test names follow the original.

///|
/// DyndepParserTest's fixture: an edge with outputs `out` and `otherout`.
fn dyndep_fixture() -> (@moonja.State, @moonja.DyndepFile) raise {
  let state = @moonja.State::new()
  @moonja.ManifestParser::without_files(state).parse_test(
    "rule touch\n  command = touch $out\nbuild out otherout: touch\n",
  )
  (state, @moonja.DyndepFile::new())
}

///|
fn dyndep_parse(
  state : @moonja.State,
  file : @moonja.DyndepFile,
  input : String,
) -> String {
  try {
    @moonja.DyndepParser::without_files(state, file).parse_test(input)
    ""
  } catch {
    error => error.message()
  }
}

///|
fn dyndep_error(input : String) -> String raise {
  let (state, file) = dyndep_fixture()
  dyndep_parse(state, file, input)
}

///|
/// AssertParse, returning the fixture for further checks.
fn dyndep_ok(input : String) -> (@moonja.State, @moonja.DyndepFile) raise {
  let (state, file) = dyndep_fixture()
  assert_eq(dyndep_parse(state, file, input), "")
  (state, file)
}

///|
fn paths(nodes : Array[@moonja.Node]) -> Array[String] {
  nodes.map(fn(n) { n.path() })
}

///|
/// (restat, implicit outputs, implicit inputs) recorded for the first edge.
fn first_dyndeps(
  state : @moonja.State,
  file : @moonja.DyndepFile,
) -> (Bool, Array[String], Array[String]) raise {
  assert_eq(file.length(), 1)
  let dyndeps = file.get(state.edges()[0]).unwrap()
  (
    dyndeps.restat(),
    paths(dyndeps.implicit_outputs()),
    paths(dyndeps.implicit_inputs()),
  )
}

///|
test "DyndepParserTest.Empty" {
  assert_eq(
    dyndep_error(""),
    "input:1: expected 'ninja_dyndep_version = ...'\n",
  )
}

///|
test "DyndepParserTest.Versions" {
  // Version1, Version1Extra, Version1_0, Version1_0Extra, CommentVersion,
  // BlankLineVersion, VersionCRLF, CommentVersionCRLF, BlankLineVersionCRLF.
  for
    input in [
      "ninja_dyndep_version = 1\n", "ninja_dyndep_version = 1-extra\n", "ninja_dyndep_version = 1.0\n",
      "ninja_dyndep_version = 1.0-extra\n", "# comment\nninja_dyndep_version = 1\n",
      "\nninja_dyndep_version = 1\n", "ninja_dyndep_version = 1\r\n", "# comment\r\nninja_dyndep_version = 1\r\n",
      "\r\nninja_dyndep_version = 1\r\n",
    ] {
    ignore(dyndep_ok(input))
  }
}

///|
test "DyndepParserTest.VersionUnexpectedEOF" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1.0"),
    "input:1: unexpected EOF\nninja_dyndep_version = 1.0\n                          ^ near here",
  )
}

///|
test "DyndepParserTest.UnsupportedVersion0" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 0\n"),
    "input:1: unsupported 'ninja_dyndep_version = 0'\nninja_dyndep_version = 0\n                        ^ near here",
  )
}

///|
test "DyndepParserTest.UnsupportedVersion1_1" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1.1\n"),
    "input:1: unsupported 'ninja_dyndep_version = 1.1'\nninja_dyndep_version = 1.1\n                          ^ near here",
  )
}

///|
test "DyndepParserTest.DuplicateVersion" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nninja_dyndep_version = 1\n"),
    "input:2: unexpected identifier\n",
  )
}

///|
test "DyndepParserTest.MissingVersionOtherVar" {
  assert_eq(
    dyndep_error("not_ninja_dyndep_version = 1\n"),
    "input:1: expected 'ninja_dyndep_version = ...'\nnot_ninja_dyndep_version = 1\n                            ^ near here",
  )
}

///|
test "DyndepParserTest.MissingVersionBuild" {
  assert_eq(
    dyndep_error("build out: dyndep\n"),
    "input:1: expected 'ninja_dyndep_version = ...'\n",
  )
}

///|
test "DyndepParserTest.UnexpectedEqual" {
  assert_eq(dyndep_error("= 1\n"), "input:1: unexpected '='\n")
}

///|
test "DyndepParserTest.UnexpectedIndent" {
  assert_eq(dyndep_error(" = 1\n"), "input:1: unexpected indent\n")
}

///|
test "DyndepParserTest.OutDuplicate" {
  assert_eq(
    dyndep_error(
      "ninja_dyndep_version = 1\nbuild out: dyndep\nbuild out: dyndep\n",
    ),
    "input:3: multiple statements for 'out'\nbuild out: dyndep\n         ^ near here",
  )
}

///|
test "DyndepParserTest.OutDuplicateThroughOther" {
  assert_eq(
    dyndep_error(
      "ninja_dyndep_version = 1\nbuild out: dyndep\nbuild otherout: dyndep\n",
    ),
    "input:3: multiple statements for 'otherout'\nbuild otherout: dyndep\n              ^ near here",
  )
}

///|
test "DyndepParserTest.NoOutEOF" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild"),
    "input:2: unexpected EOF\nbuild\n     ^ near here",
  )
}

///|
test "DyndepParserTest.NoOutColon" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild :\n"),
    "input:2: expected path\nbuild :\n      ^ near here",
  )
}

///|
test "DyndepParserTest.OutNoStatement" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild missing: dyndep\n"),
    "input:2: no build statement exists for 'missing'\nbuild missing: dyndep\n             ^ near here",
  )
}

///|
test "DyndepParserTest.OutEOF" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out"),
    "input:2: unexpected EOF\nbuild out\n         ^ near here",
  )
}

///|
test "DyndepParserTest.OutNoRule" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out:"),
    "input:2: expected build command name 'dyndep'\nbuild out:\n          ^ near here",
  )
}

///|
test "DyndepParserTest.OutBadRule" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out: touch"),
    "input:2: expected build command name 'dyndep'\nbuild out: touch\n           ^ near here",
  )
}

///|
test "DyndepParserTest.BuildEOF" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out: dyndep"),
    "input:2: unexpected EOF\nbuild out: dyndep\n                 ^ near here",
  )
}

///|
test "DyndepParserTest.ExplicitOut" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out exp: dyndep\n"),
    "input:2: explicit outputs not supported\nbuild out exp: dyndep\n             ^ near here",
  )
}

///|
test "DyndepParserTest.ExplicitIn" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out: dyndep exp\n"),
    "input:2: explicit inputs not supported\nbuild out: dyndep exp\n                     ^ near here",
  )
}

///|
test "DyndepParserTest.OrderOnlyIn" {
  assert_eq(
    dyndep_error("ninja_dyndep_version = 1\nbuild out: dyndep ||\n"),
    "input:2: order-only inputs not supported\nbuild out: dyndep ||\n                  ^ near here",
  )
}

///|
test "DyndepParserTest.BadBinding" {
  assert_eq(
    dyndep_error(
      "ninja_dyndep_version = 1\nbuild out: dyndep\n  not_restat = 1\n",
    ),
    "input:3: binding is not 'restat'\n  not_restat = 1\n                ^ near here",
  )
}

///|
test "DyndepParserTest.RestatTwice" {
  assert_eq(
    dyndep_error(
      "ninja_dyndep_version = 1\nbuild out: dyndep\n  restat = 1\n  restat = 1\n",
    ),
    "input:4: unexpected indent\n",
  )
}

///|
test "DyndepParserTest.NoImplicit" {
  let (state, file) = dyndep_ok("ninja_dyndep_version = 1\nbuild out: dyndep\n")
  assert_eq(first_dyndeps(state, file), (false, [], []))
}

///|
test "DyndepParserTest.EmptyImplicit" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out | : dyndep |\n",
  )
  assert_eq(first_dyndeps(state, file), (false, [], []))
}

///|
test "DyndepParserTest.ImplicitIn" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out: dyndep | impin\n",
  )
  assert_eq(first_dyndeps(state, file), (false, [], ["impin"]))
}

///|
test "DyndepParserTest.ImplicitIns" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out: dyndep | impin1 impin2\n",
  )
  assert_eq(first_dyndeps(state, file), (false, [], ["impin1", "impin2"]))
}

///|
test "DyndepParserTest.ImplicitOut" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out | impout: dyndep\n",
  )
  assert_eq(first_dyndeps(state, file), (false, ["impout"], []))
}

///|
test "DyndepParserTest.ImplicitOuts" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out | impout1 impout2 : dyndep\n",
  )
  assert_eq(first_dyndeps(state, file), (false, ["impout1", "impout2"], []))
}

///|
test "DyndepParserTest.ImplicitInsAndOuts" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out | impout1 impout2: dyndep | impin1 impin2\n",
  )
  assert_eq(
    first_dyndeps(state, file),
    (false, ["impout1", "impout2"], ["impin1", "impin2"]),
  )
}

///|
test "DyndepParserTest.Restat" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild out: dyndep\n  restat = 1\n",
  )
  assert_eq(first_dyndeps(state, file), (true, [], []))
}

///|
test "DyndepParserTest.OtherOutput" {
  let (state, file) = dyndep_ok(
    "ninja_dyndep_version = 1\nbuild otherout: dyndep\n",
  )
  assert_eq(first_dyndeps(state, file), (false, [], []))
}

///|
test "DyndepParserTest.MultipleEdges" {
  let (state, file) = dyndep_fixture()
  @moonja.ManifestParser::without_files(state).parse_test("build out2: touch\n")
  assert_eq(state.edges().length(), 2)
  assert_eq(paths(state.edges()[1].outputs()), ["out2"])
  assert_eq(state.edges()[0].inputs().length(), 0)
  assert_eq(
    dyndep_parse(
      state, file, "ninja_dyndep_version = 1\nbuild out: dyndep\nbuild out2: dyndep\n  restat = 1\n",
    ),
    "",
  )
  assert_eq(file.length(), 2)
  let first = file.get(state.edges()[0]).unwrap()
  assert_eq(
    (
      first.restat(),
      first.implicit_outputs().length(),
      first.implicit_inputs().length(),
    ),
    (false, 0, 0),
  )
  let second = file.get(state.edges()[1]).unwrap()
  assert_eq(
    (
      second.restat(),
      second.implicit_outputs().length(),
      second.implicit_inputs().length(),
    ),
    (true, 0, 0),
  )
}
