// Ported from ninja v1.13.2 src/edit_distance_test.cc (Apache-2.0, see
// NOTICE).

///|
test "EditDistanceTest.TestEmpty" {
  assert_eq(@moonja.edit_distance("", "ninja"), 5)
  assert_eq(@moonja.edit_distance("ninja", ""), 5)
  assert_eq(@moonja.edit_distance("", ""), 0)
}

///|
test "EditDistanceTest.TestMaxDistance" {
  for max_distance in 1..<7 {
    assert_eq(
      @moonja.edit_distance(
        "abcdefghijklmnop",
        "ponmlkjihgfedcba",
        max_edit_distance=max_distance,
      ),
      max_distance + 1,
    )
  }
}

///|
test "EditDistanceTest.TestAllowReplacements" {
  assert_eq(@moonja.edit_distance("ninja", "njnja"), 1)
  assert_eq(@moonja.edit_distance("njnja", "ninja"), 1)
  assert_eq(
    @moonja.edit_distance("ninja", "njnja", allow_replacements=false),
    2,
  )
  assert_eq(
    @moonja.edit_distance("njnja", "ninja", allow_replacements=false),
    2,
  )
}

///|
test "EditDistanceTest.TestBasics" {
  assert_eq(@moonja.edit_distance("browser_tests", "browser_tests"), 0)
  assert_eq(@moonja.edit_distance("browser_test", "browser_tests"), 1)
  assert_eq(@moonja.edit_distance("browser_tests", "browser_test"), 1)
}

///|
test "State.SpellcheckNode" {
  let state = @moonja.State::new()
  let parser = @moonja.ManifestParser::without_files(state)
  parser.parse_test("build browser_tests: phony\nbuild unit_tests: phony\n")
  assert_eq(
    state.spellcheck_node("browser_test").map(fn(n) { n.path() }),
    Some("browser_tests"),
  )
  assert_eq(
    state.spellcheck_node("unit_test").map(fn(n) { n.path() }),
    Some("unit_tests"),
  )
  assert_true(state.spellcheck_node("completely_different") is None)
}
