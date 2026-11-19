///|
/// The library example in README.md.
test "README library example" {
  let state = @moonja.State::new()
  let parser = @moonja.ManifestParser::without_files(state)
  parser.parse_test("rule cc\n  command = cc $in -o $out\nbuild a.o: cc a.c\n")
  let commands = state.edges().map(fn(edge) raise { edge.evaluate_command() })
  assert_eq(commands, ["cc a.c -o a.o"])
}
