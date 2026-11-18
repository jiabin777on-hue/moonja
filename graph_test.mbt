// Ported from ninja v1.13.2 src/graph_test.cc (Apache-2.0, see NOTICE).
// Test names follow the original. NestedPhonyPrintsDone needs the build
// Plan and lives with the build tests.

///|
/// GraphTest: a state with a `cat` rule, an in-memory disk and a scan.
struct Graph {
  state : @moonja.State
  fs : @moonja.MemoryDisk
  scan : @moonja.DependencyScan
}

///|
fn graph(
  input : String,
  options~ : @moonja.ManifestParserOptions = @moonja.ManifestParserOptions::default(),
  platform~ : @moonja.Platform = Posix,
) -> Graph raise {
  let state = @moonja.State::new(platform~)
  let parser = @moonja.ManifestParser::without_files(state, options~)
  parser.parse_test("rule cat\n  command = cat $in > $out\n")
  parser.parse_test(input)
  let fs = @moonja.MemoryDisk::new()
  { state, fs, scan: @moonja.DependencyScan::new(state, fs), }
}

///|
fn Graph::node(self : Graph, path : String) -> @moonja.Node {
  self.state.get_node(path, 0)
}

///|
fn Graph::edge(self : Graph, path : String) -> @moonja.Edge {
  self.node(path).in_edge().unwrap()
}

///|
fn Graph::dirty(self : Graph, path : String) -> Bool {
  self.node(path).dirty()
}

///|
fn Graph::recompute(self : Graph, path : String) -> Unit raise {
  self.scan.recompute_dirty(self.node(path))
}

///|
/// The error of a scan from `path`, "" if it succeeds.
fn Graph::recompute_error(self : Graph, path : String) -> String {
  try {
    self.scan.recompute_dirty(self.node(path))
    ""
  } catch {
    error => error.message()
  }
}

///|
fn Graph::load_dyndeps_error(self : Graph, path : String) -> String {
  try {
    self.scan.load_dyndeps(self.node(path))
    ""
  } catch {
    error => error.message()
  }
}

///|
fn input_paths(edge : @moonja.Edge) -> Array[String] {
  edge.inputs().map(fn(n) { n.path() })
}

///|
fn output_paths(edge : @moonja.Edge) -> Array[String] {
  edge.outputs().map(fn(n) { n.path() })
}

///|
let catdep : String = "rule catdep\n  depfile = $out.d\n  command = cat $in > $out\n"

///|
test "GraphTest.MissingImplicit" {
  let g = graph("build out: cat in | implicit\n")
  g.fs.create("in", "")
  g.fs.create("out", "")
  g.recompute("out")
  // A missing implicit dep makes the output dirty (and the build fail).
  assert_true(g.dirty("out"))
}

///|
test "GraphTest.ModifiedImplicit" {
  let g = graph("build out: cat in | implicit\n")
  g.fs.create("in", "")
  g.fs.create("out", "")
  ignore(g.fs.tick())
  g.fs.create("implicit", "")
  g.recompute("out")
  assert_true(g.dirty("out"))
}

///|
test "GraphTest.FunkyMakefilePath" {
  let g = graph(catdep + "build out.o: catdep foo.cc\n")
  g.fs.create("foo.cc", "")
  g.fs.create("out.o.d", "out.o: ./foo/../implicit.h\n")
  g.fs.create("out.o", "")
  ignore(g.fs.tick())
  g.fs.create("implicit.h", "")
  g.recompute("out.o")
  // The depfile names implicit.h with a non-canonical path; it is found.
  assert_true(g.dirty("out.o"))
}

///|
test "GraphTest.ExplicitImplicit" {
  let g = graph(
    catdep +
    "build implicit.h: cat data\nbuild out.o: catdep foo.cc || implicit.h\n",
  )
  g.fs.create("implicit.h", "")
  g.fs.create("foo.cc", "")
  g.fs.create("out.o.d", "out.o: implicit.h\n")
  g.fs.create("out.o", "")
  ignore(g.fs.tick())
  g.fs.create("data", "")
  g.recompute("out.o")
  // The implicit dep on implicit.h wins over the order-only one.
  assert_true(g.dirty("out.o"))
}

///|
test "GraphTest.ImplicitOutputParse" {
  let g = graph("build out | out.imp: cat in\n")
  let edge = g.edge("out")
  assert_eq(output_paths(edge), ["out", "out.imp"])
  assert_eq(edge.implicit_outs(), 1)
  assert_true(physical_equal(g.edge("out.imp"), edge))
}

///|
test "GraphTest.ImplicitOutputMissing" {
  let g = graph("build out | out.imp: cat in\n")
  g.fs.create("in", "")
  g.fs.create("out", "")
  g.recompute("out")
  assert_true(g.dirty("out"))
  assert_true(g.dirty("out.imp"))
}

///|
test "GraphTest.ImplicitOutputOutOfDate" {
  let g = graph("build out | out.imp: cat in\n")
  g.fs.create("out.imp", "")
  ignore(g.fs.tick())
  g.fs.create("in", "")
  g.fs.create("out", "")
  g.recompute("out")
  assert_true(g.dirty("out"))
  assert_true(g.dirty("out.imp"))
}

///|
test "GraphTest.ImplicitOutputOnlyParse" {
  let g = graph("build | out.imp: cat in\n")
  let edge = g.edge("out.imp")
  assert_eq(output_paths(edge), ["out.imp"])
  assert_eq(edge.implicit_outs(), 1)
}

///|
test "GraphTest.ImplicitOutputOnlyMissing" {
  let g = graph("build | out.imp: cat in\n")
  g.fs.create("in", "")
  g.recompute("out.imp")
  assert_true(g.dirty("out.imp"))
}

///|
test "GraphTest.ImplicitOutputOnlyOutOfDate" {
  let g = graph("build | out.imp: cat in\n")
  g.fs.create("out.imp", "")
  ignore(g.fs.tick())
  g.fs.create("in", "")
  g.recompute("out.imp")
  assert_true(g.dirty("out.imp"))
}

///|
test "GraphTest.PathWithCurrentDirectory" {
  let g = graph(catdep + "build ./out.o: catdep ./foo.cc\n")
  g.fs.create("foo.cc", "")
  g.fs.create("out.o.d", "out.o: foo.cc\n")
  g.fs.create("out.o", "")
  g.recompute("out.o")
  assert_false(g.dirty("out.o"))
}

///|
test "GraphTest.RootNodes" {
  let g = graph(
    "build out1: cat in1\nbuild mid1: cat in1\nbuild out2: cat mid1\nbuild out3 out4: cat mid1\n",
  )
  let roots = g.state.root_nodes()
  assert_eq(roots.length(), 4)
  for root in roots {
    assert_true(root.path().has_prefix("out"))
  }
}

///|
let collector_graph : String =
  #|build out1: cat in1
  #|build mid1: cat in1
  #|build out2: cat mid1
  #|build out3 out4: cat mid1
  #|build all: phony out1 out2 out3
  #|

///|
test "GraphTest.InputsCollector" {
  let g = graph(collector_graph)
  let collector = @moonja.InputsCollector::new()
  // From out1: in1.
  collector.visit_node(g.node("out1"))
  assert_eq(collector.inputs_as_strings(), ["in1"])
  // Then out2 adds mid1.
  collector.visit_node(g.node("out2"))
  assert_eq(collector.inputs_as_strings(), ["in1", "mid1"])
  // Then all adds out1, out2 and out3 but not out4.
  collector.visit_node(g.node("all"))
  assert_eq(collector.inputs_as_strings(), [
    "in1", "mid1", "out1", "out2", "out3",
  ])
  collector.reset()
  // Starting from all puts out1 before mid1.
  collector.visit_node(g.node("all"))
  assert_eq(collector.inputs_as_strings(), [
    "in1", "out1", "mid1", "out2", "out3",
  ])
}

///|
test "GraphTest.InputsCollectorWithEscapes" {
  let input = "build out$ 1: cat in1 in2 in$ with$ space | implicit || order_only\n"
  let g = graph(input)
  let collector = @moonja.InputsCollector::new()
  collector.visit_node(g.node("out 1"))
  assert_eq(collector.inputs_as_strings(), [
    "in1", "in2", "in with space", "implicit", "order_only",
  ])
  assert_eq(collector.inputs_as_strings(escape=true), [
    "in1", "in2", "'in with space'", "implicit", "order_only",
  ])
  let w = graph(input, platform=Windows)
  let collector = @moonja.InputsCollector::new(platform=Windows)
  collector.visit_node(w.node("out 1"))
  assert_eq(collector.inputs_as_strings(escape=true)[2], "\"in with space\"")
}

///|
test "GraphTest.CommandCollector" {
  let g = graph(collector_graph)
  let commands = fn(collector : @moonja.CommandCollector) raise {
    let out = []
    for e in collector.in_edges() {
      out.push(e.evaluate_command())
    }
    out
  }
  let collector = @moonja.CommandCollector::new()
  // From out2: mid1 and out2.
  collector.collect_from(g.node("out2"))
  assert_eq(commands(collector), ["cat in1 > mid1", "cat mid1 > out2"])
  // Then out1.
  collector.collect_from(g.node("out1"))
  assert_eq(commands(collector), [
    "cat in1 > mid1", "cat mid1 > out2", "cat in1 > out1",
  ])
  // Then all: out3, but not the phony edge itself.
  collector.collect_from(g.node("all"))
  assert_eq(commands(collector), [
    "cat in1 > mid1", "cat mid1 > out2", "cat in1 > out1", "cat mid1 > out3 out4",
  ])
  // Starting from all puts out1 first.
  let collector = @moonja.CommandCollector::new()
  collector.collect_from(g.node("all"))
  assert_eq(commands(collector), [
    "cat in1 > out1", "cat in1 > mid1", "cat mid1 > out2", "cat mid1 > out3 out4",
  ])
}

///|
test "GraphTest.VarInOutPathEscaping" {
  let input = "build a$ b: cat no'space with$ space$$ no\"space2\n"
  let g = graph(input)
  assert_eq(
    g.edge("a b").evaluate_command(),
    "cat 'no'\\''space' 'with space$' 'no\"space2' > 'a b'",
  )
  let w = graph(input, platform=Windows)
  assert_eq(
    w.edge("a b").evaluate_command(),
    "cat no'space \"with space$\" \"no\\\"space2\" > \"a b\"",
  )
}

///|
test "GraphTest.DepfileWithCanonicalizablePath" {
  // https://github.com/ninja-build/ninja/issues/380
  let g = graph(catdep + "build ./out.o: catdep ./foo.cc\n")
  g.fs.create("foo.cc", "")
  g.fs.create("out.o.d", "out.o: bar/../foo.cc\n")
  g.fs.create("out.o", "")
  g.recompute("out.o")
  assert_false(g.dirty("out.o"))
}

///|
test "GraphTest.DepfileRemoved" {
  // https://github.com/ninja-build/ninja/issues/404
  let g = graph(catdep + "build ./out.o: catdep ./foo.cc\n")
  g.fs.create("foo.h", "")
  g.fs.create("foo.cc", "")
  ignore(g.fs.tick())
  g.fs.create("out.o.d", "out.o: foo.h\n")
  g.fs.create("out.o", "")
  g.recompute("out.o")
  assert_false(g.dirty("out.o"))
  g.state.reset()
  ignore(@moonja.Disk::remove_file(g.fs, "out.o.d"))
  g.recompute("out.o")
  assert_true(g.dirty("out.o"))
}

///|
test "GraphTest.RuleVariablesInScope" {
  let g = graph(
    "rule r\n  depfile = x\n  command = depfile is $depfile\nbuild out: r in\n",
  )
  assert_eq(g.edge("out").evaluate_command(), "depfile is x")
}

///|
test "GraphTest.DepfileOverride" {
  // Build statements can override rule bindings like depfile.
  let g = graph(
    "rule r\n  depfile = x\n  command = unused\nbuild out: r in\n  depfile = y\n",
  )
  assert_eq(g.edge("out").get_binding("depfile"), "y")
}

///|
test "GraphTest.DepfileOverrideParent" {
  // The override shows in the expansion of rule bindings.
  let g = graph(
    "rule r\n  depfile = x\n  command = depfile is $depfile\nbuild out: r in\n  depfile = y\n",
  )
  assert_eq(g.edge("out").get_binding("command"), "depfile is y")
}

///|
test "GraphTest.PhonySelfReferenceError" {
  let g = graph("build a: phony a\n", options={ phony_cycle_action: Error, })
  assert_eq(
    g.recompute_error("a"),
    "dependency cycle: a -> a [-w phonycycle=err]",
  )
}

///|
test "GraphTest.DependencyCycle" {
  let g = graph(
    "build out: cat mid\nbuild mid: cat in\nbuild in: cat pre\nbuild pre: cat out\n",
  )
  assert_eq(
    g.recompute_error("out"),
    "dependency cycle: out -> mid -> in -> pre -> out",
  )
}

///|
test "GraphTest.CycleInEdgesButNotInNodes1" {
  let g = graph("build a b: cat a\n")
  assert_eq(g.recompute_error("b"), "dependency cycle: a -> a")
}

///|
test "GraphTest.CycleInEdgesButNotInNodes2" {
  let g = graph("build b a: cat a\n")
  assert_eq(g.recompute_error("b"), "dependency cycle: a -> a")
}

///|
test "GraphTest.CycleInEdgesButNotInNodes3" {
  let g = graph("build a b: cat c\nbuild c: cat a\n")
  assert_eq(g.recompute_error("b"), "dependency cycle: a -> c -> a")
}

///|
test "GraphTest.CycleInEdgesButNotInNodes4" {
  let g = graph(
    "build d: cat c\nbuild c: cat b\nbuild b: cat a\nbuild a e: cat d\nbuild f: cat e\n",
  )
  assert_eq(g.recompute_error("f"), "dependency cycle: a -> d -> c -> b -> a")
}

///|
test "GraphTest.CycleWithLengthZeroFromDepfile" {
  // A depfile that closes a cycle must not be loaded twice.
  let g = graph(
    "rule deprule\n   depfile = dep.d\n   command = unused\nbuild a b: deprule\n",
  )
  g.fs.create("dep.d", "a: b\n")
  assert_eq(g.recompute_error("a"), "dependency cycle: b -> b")
  assert_eq(input_paths(g.edge("a")), ["b"])
}

///|
test "GraphTest.CycleWithLengthOneFromDepfile" {
  let g = graph(
    "rule deprule\n   depfile = dep.d\n   command = unused\nrule r\n   command = unused\nbuild a b: deprule\nbuild c: r b\n",
  )
  g.fs.create("dep.d", "a: c\n")
  assert_eq(g.recompute_error("a"), "dependency cycle: b -> c -> b")
  assert_eq(input_paths(g.edge("a")), ["c"])
}

///|
test "GraphTest.CycleWithLengthOneFromDepfileOneHopAway" {
  let g = graph(
    "rule deprule\n   depfile = dep.d\n   command = unused\nrule r\n   command = unused\nbuild a b: deprule\nbuild c: r b\nbuild d: r a\n",
  )
  g.fs.create("dep.d", "a: c\n")
  assert_eq(g.recompute_error("d"), "dependency cycle: b -> c -> b")
  assert_eq(input_paths(g.edge("a")), ["c"])
}

///|
test "GraphTest.Decanonicalize" {
  let g = graph(
    "build out\\out1: cat src\\in1\nbuild out\\out2/out3\\out4: cat mid1\nbuild out3 out4\\foo: cat mid1\n",
    platform=Windows,
  )
  let roots = g.state.root_nodes()
  assert_eq(roots.map(fn(n) { n.path() }), [
    "out/out1", "out/out2/out3/out4", "out3", "out4/foo",
  ])
  assert_eq(roots.map(fn(n) { n.path_decanonicalized(Windows) }), [
    "out\\out1", "out\\out2/out3\\out4", "out3", "out4\\foo",
  ])
}

///|
test "GraphTest.DyndepLoadTrivial" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r in || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd", "ninja_dyndep_version = 1\nbuild out: dyndep\n")
  assert_true(g.node("dd").dyndep_pending())
  assert_eq(g.load_dyndeps_error("dd"), "")
  assert_false(g.node("dd").dyndep_pending())
  let edge = g.edge("out")
  assert_eq(output_paths(edge), ["out"])
  assert_eq(input_paths(edge), ["in", "dd"])
  assert_eq((edge.implicit_deps(), edge.order_only_deps()), (0, 1))
  assert_false(edge.get_binding_bool("restat"))
}

///|
test "GraphTest.DyndepLoadImplicit" {
  let g = graph(
    "rule r\n  command = unused\nbuild out1: r in || dd\n  dyndep = dd\nbuild out2: r in\n",
  )
  g.fs.create("dd", "ninja_dyndep_version = 1\nbuild out1: dyndep | out2\n")
  assert_true(g.node("dd").dyndep_pending())
  assert_eq(g.load_dyndeps_error("dd"), "")
  assert_false(g.node("dd").dyndep_pending())
  let edge = g.edge("out1")
  assert_eq(output_paths(edge), ["out1"])
  assert_eq(input_paths(edge), ["in", "out2", "dd"])
  assert_eq((edge.implicit_deps(), edge.order_only_deps()), (1, 1))
  assert_false(edge.get_binding_bool("restat"))
}

///|
test "GraphTest.DyndepLoadMissingFile" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r in || dd\n  dyndep = dd\n",
  )
  assert_true(g.node("dd").dyndep_pending())
  assert_eq(
    g.load_dyndeps_error("dd"),
    "loading 'dd': No such file or directory",
  )
}

///|
test "GraphTest.DyndepLoadMissingEntry" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r in || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd", "ninja_dyndep_version = 1\n")
  assert_eq(
    g.load_dyndeps_error("dd"),
    "'out' not mentioned in its dyndep file 'dd'",
  )
}

///|
test "GraphTest.DyndepLoadExtraEntry" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r in || dd\n  dyndep = dd\nbuild out2: r in || dd\n",
  )
  g.fs.create(
    "dd", "ninja_dyndep_version = 1\nbuild out: dyndep\nbuild out2: dyndep\n",
  )
  assert_eq(
    g.load_dyndeps_error("dd"),
    "dyndep file 'dd' mentions output 'out2' whose build statement does not have a dyndep binding for the file",
  )
}

///|
test "GraphTest.DyndepLoadOutputWithMultipleRules1" {
  let g = graph(
    "rule r\n  command = unused\nbuild out1 | out-twice.imp: r in1\nbuild out2: r in2 || dd\n  dyndep = dd\n",
  )
  g.fs.create(
    "dd", "ninja_dyndep_version = 1\nbuild out2 | out-twice.imp: dyndep\n",
  )
  assert_eq(g.load_dyndeps_error("dd"), "multiple rules generate out-twice.imp")
}

///|
test "GraphTest.DyndepLoadOutputWithMultipleRules2" {
  let g = graph(
    "rule r\n  command = unused\nbuild out1: r in1 || dd1\n  dyndep = dd1\nbuild out2: r in2 || dd2\n  dyndep = dd2\n",
  )
  g.fs.create(
    "dd1", "ninja_dyndep_version = 1\nbuild out1 | out-twice.imp: dyndep\n",
  )
  g.fs.create(
    "dd2", "ninja_dyndep_version = 1\nbuild out2 | out-twice.imp: dyndep\n",
  )
  assert_eq(g.load_dyndeps_error("dd1"), "")
  assert_eq(
    g.load_dyndeps_error("dd2"),
    "multiple rules generate out-twice.imp",
  )
}

///|
test "GraphTest.DyndepLoadMultiple" {
  let g = graph(
    "rule r\n  command = unused\nbuild out1: r in1 || dd\n  dyndep = dd\nbuild out2: r in2 || dd\n  dyndep = dd\nbuild outNot: r in3 || dd\n",
  )
  g.fs.create(
    "dd", "ninja_dyndep_version = 1\nbuild out1 | out1imp: dyndep | in1imp\nbuild out2: dyndep | in2imp\n  restat = 1\n",
  )
  assert_eq(g.load_dyndeps_error("dd"), "")
  assert_false(g.node("dd").dyndep_pending())
  let edge1 = g.edge("out1")
  assert_eq(output_paths(edge1), ["out1", "out1imp"])
  assert_eq(edge1.implicit_outs(), 1)
  assert_eq(input_paths(edge1), ["in1", "in1imp", "dd"])
  assert_eq((edge1.implicit_deps(), edge1.order_only_deps()), (1, 1))
  assert_false(edge1.get_binding_bool("restat"))
  assert_true(physical_equal(g.edge("out1imp"), edge1))
  let in1imp = g.node("in1imp").out_edges()
  assert_eq(in1imp.length(), 1)
  assert_true(physical_equal(in1imp[0], edge1))
  let edge2 = g.edge("out2")
  assert_eq(output_paths(edge2), ["out2"])
  assert_eq(edge2.implicit_outs(), 0)
  assert_eq(input_paths(edge2), ["in2", "in2imp", "dd"])
  assert_eq((edge2.implicit_deps(), edge2.order_only_deps()), (1, 1))
  assert_true(edge2.get_binding_bool("restat"))
  let in2imp = g.node("in2imp").out_edges()
  assert_eq(in2imp.length(), 1)
  assert_true(physical_equal(in2imp[0], edge2))
}

///|
test "GraphTest.DyndepFileMissing" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r || dd\n  dyndep = dd\n",
  )
  assert_eq(g.recompute_error("out"), "loading 'dd': No such file or directory")
}

///|
test "GraphTest.DyndepFileError" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd", "ninja_dyndep_version = 1\n")
  assert_eq(
    g.recompute_error("out"),
    "'out' not mentioned in its dyndep file 'dd'",
  )
}

///|
test "GraphTest.DyndepImplicitInputNewer" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd", "ninja_dyndep_version = 1\nbuild out: dyndep | in\n")
  g.fs.create("out", "")
  ignore(g.fs.tick())
  g.fs.create("in", "")
  g.recompute("out")
  assert_false(g.dirty("in"))
  assert_false(g.dirty("dd"))
  // Dirty because of the implicit input from the dyndep file.
  assert_true(g.dirty("out"))
}

///|
test "GraphTest.DyndepFileReady" {
  let g = graph(
    "rule r\n  command = unused\nbuild dd: r dd-in\nbuild out: r || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd-in", "")
  g.fs.create("dd", "ninja_dyndep_version = 1\nbuild out: dyndep | in\n")
  g.fs.create("out", "")
  ignore(g.fs.tick())
  g.fs.create("in", "")
  g.recompute("out")
  assert_false(g.dirty("in"))
  assert_false(g.dirty("dd"))
  assert_true(g.edge("dd").outputs_ready())
  assert_true(g.dirty("out"))
}

///|
test "GraphTest.DyndepFileNotClean" {
  let g = graph(
    "rule r\n  command = unused\nbuild dd: r dd-in\nbuild out: r || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd", "this-should-not-be-loaded")
  ignore(g.fs.tick())
  g.fs.create("dd-in", "")
  g.fs.create("out", "")
  g.recompute("out")
  assert_true(g.dirty("dd"))
  assert_false(g.edge("dd").outputs_ready())
  // Clean, but not ready because dd is not.
  assert_false(g.dirty("out"))
  assert_false(g.edge("out").outputs_ready())
}

///|
test "GraphTest.DyndepFileNotReady" {
  let g = graph(
    "rule r\n  command = unused\nbuild tmp: r\nbuild dd: r dd-in || tmp\nbuild out: r || dd\n  dyndep = dd\n",
  )
  g.fs.create("dd", "this-should-not-be-loaded")
  g.fs.create("dd-in", "")
  ignore(g.fs.tick())
  g.fs.create("out", "")
  g.recompute("out")
  assert_false(g.dirty("dd"))
  assert_false(g.edge("dd").outputs_ready())
  assert_false(g.dirty("out"))
  assert_false(g.edge("out").outputs_ready())
}

///|
test "GraphTest.DyndepFileSecondNotReady" {
  let g = graph(
    "rule r\n  command = unused\nbuild dd1: r dd1-in\nbuild dd2-in: r || dd1\n  dyndep = dd1\nbuild dd2: r dd2-in\nbuild out: r || dd2\n  dyndep = dd2\n",
  )
  g.fs.create("dd1", "")
  g.fs.create("dd2", "")
  g.fs.create("dd2-in", "")
  ignore(g.fs.tick())
  g.fs.create("dd1-in", "")
  g.fs.create("out", "")
  g.recompute("out")
  assert_true(g.dirty("dd1"))
  assert_false(g.edge("dd1").outputs_ready())
  assert_false(g.dirty("dd2"))
  assert_false(g.edge("dd2").outputs_ready())
  assert_false(g.dirty("out"))
  assert_false(g.edge("out").outputs_ready())
}

///|
test "GraphTest.DyndepFileCircular" {
  let g = graph(
    "rule r\n  command = unused\nbuild out: r in || dd\n  depfile = out.d\n  dyndep = dd\nbuild in: r circ\n",
  )
  g.fs.create("out.d", "out: inimp\n")
  g.fs.create("dd", "ninja_dyndep_version = 1\nbuild out | circ: dyndep\n")
  g.fs.create("out", "")
  let edge = g.edge("out")
  assert_eq(g.recompute_error("out"), "dependency cycle: circ -> in -> circ")
  // out.d was loaded once despite the cycle the dyndep file creates.
  assert_eq(input_paths(edge), ["in", "inimp", "dd"])
  assert_eq((edge.implicit_deps(), edge.order_only_deps()), (1, 1))
}

///|
test "GraphTest.Validation" {
  let g = graph("build out: cat in |@ validate\nbuild validate: cat in\n")
  g.fs.create("in", "")
  let validation_nodes = []
  g.scan.recompute_dirty(g.node("out"), validation_nodes~)
  assert_eq(validation_nodes.map(fn(n) { n.path() }), ["validate"])
  assert_true(g.dirty("out"))
  assert_true(g.dirty("validate"))
}

///|
test "GraphTest.PhonyDepsMtimes" {
  // The mtimes of a phony edge's inputs propagate to it.
  let g = graph(
    "rule touch\n command = touch $out\nbuild in_ph: phony in1\nbuild out1: touch in_ph\n",
  )
  g.fs.create("in1", "")
  g.fs.create("out1", "")
  let out1 = g.node("out1")
  let in1 = g.node("in1")
  g.recompute("out1")
  assert_false(out1.dirty())
  in1.stat(g.fs)
  out1.stat(g.fs)
  let out1_mtime = out1.mtime()
  let in1_mtime = in1.mtime()
  // Touching in1 makes out1 dirty.
  g.state.reset()
  ignore(g.fs.tick())
  g.fs.create("in1", "")
  in1.stat(g.fs)
  assert_true(in1.mtime() > in1_mtime)
  g.recompute("out1")
  assert_true(in1.mtime() > in1_mtime)
  assert_eq(out1.mtime(), out1_mtime)
  assert_true(out1.dirty())
}

///|
test "GraphTest.EdgeQueuePriority" {
  let g = graph(
    "rule r\n  command = unused\nbuild out1: r in1\nbuild out2: r in2\nbuild out3: r in3\n",
  )
  let edges = [g.edge("out1"), g.edge("out2"), g.edge("out3")]
  // Largest critical path weight first.
  for i, edge in edges {
    edge.set_critical_path_weight((i * 10).to_int64())
  }
  let queue = @moonja.EdgePriorityQueue::new()
  for edge in edges {
    queue.push(edge)
  }
  assert_eq(queue.length(), 3)
  for i in 0..<3 {
    assert_true(physical_equal(queue.pop().unwrap(), edges[2 - i]))
  }
  assert_true(queue.is_empty())
  // On ties, the lowest edge id first.
  for edge in edges {
    edge.set_critical_path_weight(0)
  }
  queue.push(edges[1])
  queue.push(edges[2])
  queue.push(edges[0])
  for i in 0..<3 {
    assert_true(physical_equal(queue.pop().unwrap(), edges[i]))
  }
  assert_true(queue.is_empty())
}
