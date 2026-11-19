// Ported from ninja v1.13.2 src/missing_deps_test.cc and src/json_test.cc
// (Apache-2.0, see NOTICE).

///|
struct MissingDepsFixture {
  state : @moonja.State
  fs : @moonja.MemoryDisk
  deps_log : @moonja.DepsLog
  generator_rule : @moonja.Rule
  compile_rule : @moonja.Rule
  scanner : @moonja.MissingDependencyScanner
}

///|
fn missing_deps_fixture() -> MissingDepsFixture raise {
  let state = @moonja.State::new()
  let fs = @moonja.MemoryDisk::new()
  let deps_log = @moonja.DepsLog::new()
  deps_log.open_for_write(fs, "MissingDepTest-tempdepslog")
  {
    state,
    fs,
    deps_log,
    generator_rule: @moonja.Rule::new("generator_rule"),
    compile_rule: @moonja.Rule::new("compile_rule"),
    scanner: @moonja.MissingDependencyScanner::new(deps_log, state, fs),
  }
}

///|
fn MissingDepsFixture::record_dep(
  self : MissingDepsFixture,
  from : String,
  to : String,
) -> Unit raise {
  self.deps_log.record_deps(self.fs, self.state.lookup_node(from).unwrap(), 0, [
    self.state.lookup_node(to).unwrap(),
  ])
}

///|
fn MissingDepsFixture::process_all_nodes(
  self : MissingDepsFixture,
) -> Unit raise {
  for node in self.state.root_nodes() {
    self.scanner.process_node(node)
  }
}

///|
fn MissingDepsFixture::create_initial_state(
  self : MissingDepsFixture,
) -> Unit raise {
  let gcc = @moonja.EvalString::new()
  gcc.add_text("gcc")
  self.compile_rule.add_binding("deps", gcc)
  self.generator_rule.add_binding("deps", gcc)
  let header_edge = self.state.add_edge(self.generator_rule)
  self.state.add_out(header_edge, "generated_header", 0)
  let compile_edge = self.state.add_edge(self.compile_rule)
  self.state.add_out(compile_edge, "compiled_object", 0)
}

///|
fn MissingDepsFixture::depend(
  self : MissingDepsFixture,
  from : String,
  to : String,
) -> Unit {
  let edge = self.state.lookup_node(from).unwrap().in_edge().unwrap()
  self.state.add_in(edge, to, 0)
}

///|
fn MissingDepsFixture::assert_missing(
  self : MissingDepsFixture,
  flaky : String,
  generated : String,
  rule : @moonja.Rule,
) -> Unit raise {
  let has = fn(nodes : Array[@moonja.Node], path : String) {
    nodes.iter().any(fn(n) { n.path() == path })
  }
  assert_true(has(self.scanner.nodes_missing_deps(), flaky))
  assert_true(has(self.scanner.generated_nodes(), generated))
  assert_true(
    self.scanner.generator_rules().iter().any(fn(r) { physical_equal(r, rule) }),
  )
}

///|
test "MissingDependencyScannerTest.EmptyGraph" {
  let f = missing_deps_fixture()
  f.process_all_nodes()
  assert_false(f.scanner.had_missing_deps())
}

///|
test "MissingDependencyScannerTest.NoMissingDep" {
  let f = missing_deps_fixture()
  f.create_initial_state()
  f.process_all_nodes()
  assert_false(f.scanner.had_missing_deps())
}

///|
test "MissingDependencyScannerTest.MissingDepPresent" {
  let f = missing_deps_fixture()
  f.create_initial_state()
  // compiled_object uses generated_header without a dependency on it.
  f.record_dep("compiled_object", "generated_header")
  f.process_all_nodes()
  assert_true(f.scanner.had_missing_deps())
  assert_eq(f.scanner.nodes_missing_deps().length(), 1)
  assert_eq(f.scanner.missing_dep_path_count(), 1)
  f.assert_missing("compiled_object", "generated_header", f.generator_rule)
}

///|
test "MissingDependencyScannerTest.MissingDepFixedDirect" {
  let f = missing_deps_fixture()
  f.create_initial_state()
  f.depend("compiled_object", "generated_header")
  f.record_dep("compiled_object", "generated_header")
  f.process_all_nodes()
  assert_false(f.scanner.had_missing_deps())
}

///|
test "MissingDependencyScannerTest.MissingDepFixedIndirect" {
  let f = missing_deps_fixture()
  f.create_initial_state()
  let intermediate = f.state.add_edge(f.generator_rule)
  f.state.add_out(intermediate, "intermediate", 0)
  f.depend("compiled_object", "intermediate")
  f.depend("intermediate", "generated_header")
  f.record_dep("compiled_object", "generated_header")
  f.process_all_nodes()
  assert_false(f.scanner.had_missing_deps())
}

///|
test "MissingDependencyScannerTest.CyclicMissingDep" {
  let f = missing_deps_fixture()
  f.create_initial_state()
  f.record_dep("generated_header", "compiled_object")
  f.record_dep("compiled_object", "generated_header")
  // Both paths are reported; no added dep could fix a cycle.
  f.process_all_nodes()
  assert_true(f.scanner.had_missing_deps())
  assert_eq(f.scanner.nodes_missing_deps().length(), 2)
  assert_eq(f.scanner.missing_dep_path_count(), 2)
  f.assert_missing("compiled_object", "generated_header", f.generator_rule)
  f.assert_missing("generated_header", "compiled_object", f.compile_rule)
}

///|
test "MissingDependencyScannerTest.CycleInGraph" {
  let f = missing_deps_fixture()
  f.create_initial_state()
  f.depend("compiled_object", "generated_header")
  f.depend("generated_header", "compiled_object")
  // Loading the graph fails before the tool runs.
  let failed = try {
    ignore(f.state.root_nodes())
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "JSONTest.RegularAscii" {
  assert_eq(@moonja.encode_json_string("foo bar"), "foo bar")
}

///|
test "JSONTest.EscapedChars" {
  assert_eq(
    @moonja.encode_json_string("\"\\\b\u{c}\n\r\t"),
    "\\\"\\\\\\b\\f\\n\\r\\t",
  )
}

///|
test "JSONTest.ControlChars" {
  assert_eq(@moonja.encode_json_string("\u{1}\u{1f}"), "\\u0001\\u001f")
}

///|
test "JSONTest.UTF8" {
  // Non-ASCII passes through: JSON allows it.
  assert_eq(@moonja.encode_json_string("你好"), "你好")
}
