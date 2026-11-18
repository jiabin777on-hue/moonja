// Ported from ninja v1.13.2 src/build_test.cc, the PlanTest cases
// (Apache-2.0, see NOTICE). Test names follow the original.

///|
/// Orders strings code unit by code unit, like std::string's operator<.
fn lex_compare(a : String, b : String) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a.unsafe_get(i) != b.unsafe_get(i) {
      return a.unsafe_get(i).compare(b.unsafe_get(i))
    }
  }
  a.length().compare(b.length())
}

///|
/// PlanTest: a state with a `cat` rule and a plan.
struct PlanFixture {
  state : @moonja.State
  plan : @moonja.Plan
}

///|
fn plan_fixture(input : String) -> PlanFixture raise {
  { state: state_with_cat(input), plan: @moonja.Plan::new(), }
}

///|
fn PlanFixture::dirty(self : PlanFixture, paths : Array[String]) -> Unit {
  for path in paths {
    self.state.get_node(path, 0).set_dirty(true)
  }
}

///|
fn PlanFixture::prepare_for_target(
  self : PlanFixture,
  target : String,
) -> Unit raise {
  self.plan.add_target(self.state.get_node(target, 0))
  self.plan.prepare_queue()
  assert_true(self.plan.more_to_do())
}

///|
/// The next edge, as (first input, first output).
fn PlanFixture::work(self : PlanFixture) -> @moonja.Edge raise {
  match self.plan.find_work() {
    Some(edge) => edge
    None => fail("expected work")
  }
}

///|
fn PlanFixture::finish(
  self : PlanFixture,
  edge : @moonja.Edge,
  result~ : @moonja.EdgeResult = EdgeSucceeded,
) -> Unit raise {
  self.plan.edge_finished(edge, result)
}

///|
/// FindWorkSorted: takes `count` edges, then expects no more.
fn PlanFixture::find_work_sorted(
  self : PlanFixture,
  count : Int32,
) -> Array[@moonja.Edge] raise {
  let edges = []
  for _ in 0..<count {
    assert_true(self.plan.more_to_do())
    edges.push(self.work())
  }
  assert_true(self.plan.find_work() is None)
  edges.sort_by(fn(a, b) {
    lex_compare(a.outputs()[0].path(), b.outputs()[0].path())
  })
  edges
}

///|
fn ends(edge : @moonja.Edge) -> (String, String) {
  (edge.inputs()[0].path(), edge.outputs()[0].path())
}

///|
test "PlanTest.Basic" {
  let f = plan_fixture("build out: cat mid\nbuild mid: cat in\n")
  f.dirty(["mid", "out"])
  f.prepare_for_target("out")
  let edge = f.work()
  assert_eq(ends(edge), ("in", "mid"))
  assert_true(f.plan.find_work() is None)
  f.finish(edge)
  let edge = f.work()
  assert_eq(ends(edge), ("mid", "out"))
  f.finish(edge)
  assert_false(f.plan.more_to_do())
  assert_true(f.plan.find_work() is None)
}

///|
test "PlanTest.DoubleOutputDirect" {
  // Two outputs of one rule feed the next.
  let f = plan_fixture("build out: cat mid1 mid2\nbuild mid1 mid2: cat in\n")
  f.dirty(["mid1", "mid2", "out"])
  f.prepare_for_target("out")
  f.finish(f.work()) // cat in
  f.finish(f.work()) // cat mid1 mid2
  assert_true(f.plan.find_work() is None)
}

///|
test "PlanTest.DoubleOutputIndirect" {
  // Two outputs of one rule eventually reach another.
  let f = plan_fixture(
    "build out: cat b1 b2\nbuild b1: cat a1\nbuild b2: cat a2\nbuild a1 a2: cat in\n",
  )
  f.dirty(["a1", "a2", "b1", "b2", "out"])
  f.prepare_for_target("out")
  for _ in 0..<4 {
    f.finish(f.work())
  }
  assert_true(f.plan.find_work() is None)
}

///|
test "PlanTest.DoubleDependent" {
  // Two edges from one output both run.
  let f = plan_fixture(
    "build out: cat a1 a2\nbuild a1: cat mid\nbuild a2: cat mid\nbuild mid: cat in\n",
  )
  f.dirty(["mid", "a1", "a2", "out"])
  f.prepare_for_target("out")
  for _ in 0..<4 {
    f.finish(f.work())
  }
  assert_true(f.plan.find_work() is None)
}

///|
fn test_pool_with_depth_one(input : String) -> Unit raise {
  let f = plan_fixture(input)
  f.dirty(["out1", "out2"])
  f.plan.add_target(f.state.get_node("out1", 0))
  f.plan.add_target(f.state.get_node("out2", 0))
  f.plan.prepare_queue()
  assert_true(f.plan.more_to_do())
  let edge = f.work()
  assert_eq(ends(edge), ("in", "out1"))
  // The pool serializes the edges.
  assert_true(f.plan.find_work() is None)
  f.finish(edge)
  let edge = f.work()
  assert_eq(ends(edge), ("in", "out2"))
  assert_true(f.plan.find_work() is None)
  f.finish(edge)
  assert_false(f.plan.more_to_do())
  assert_true(f.plan.find_work() is None)
}

///|
test "PlanTest.PoolWithDepthOne" {
  test_pool_with_depth_one(
    "pool foobar\n  depth = 1\nrule poolcat\n  command = cat $in > $out\n  pool = foobar\nbuild out1: poolcat in\nbuild out2: poolcat in\n",
  )
}

///|
test "PlanTest.ConsolePool" {
  test_pool_with_depth_one(
    "rule poolcat\n  command = cat $in > $out\n  pool = console\nbuild out1: poolcat in\nbuild out2: poolcat in\n",
  )
}

///|
test "PlanTest.PoolsWithDepthTwo" {
  let f = plan_fixture(
    (
      #|pool foobar
      #|  depth = 2
      #|pool bazbin
      #|  depth = 2
      #|rule foocat
      #|  command = cat $in > $out
      #|  pool = foobar
      #|rule bazcat
      #|  command = cat $in > $out
      #|  pool = bazbin
      #|build out1: foocat in
      #|build out2: foocat in
      #|build out3: foocat in
      #|build outb1: bazcat in
      #|build outb2: bazcat in
      #|build outb3: bazcat in
      #|  pool =
      #|build allTheThings: cat out1 out2 out3 outb1 outb2 outb3
      #|
    ),
  )
  f.dirty(["out1", "out2", "out3", "outb1", "outb2", "outb3", "allTheThings"])
  f.prepare_for_target("allTheThings")
  let edges = f.find_work_sorted(5)
  assert_eq(edges.map(ends), [
    ("in", "out1"),
    ("in", "out2"),
    ("in", "outb1"),
    ("in", "outb2"),
    // outb3 is exempt: its pool is empty.
    ("in", "outb3"),
  ])
  // Finishing out1 makes out3 available.
  f.finish(edges[0])
  let out3 = f.work()
  assert_eq(ends(out3), ("in", "out3"))
  assert_true(f.plan.find_work() is None)
  f.finish(out3)
  assert_true(f.plan.find_work() is None)
  for i in 1..<edges.length() {
    f.finish(edges[i])
  }
  let last = f.work()
  assert_eq(last.outputs()[0].path(), "allTheThings")
  f.finish(last)
  assert_false(f.plan.more_to_do())
  assert_true(f.plan.find_work() is None)
}

///|
test "PlanTest.PoolWithRedundantEdges" {
  let f = plan_fixture(
    (
      #|pool compile
      #|  depth = 1
      #|rule gen_foo
      #|  command = touch foo.cpp
      #|rule gen_bar
      #|  command = touch bar.cpp
      #|rule echo
      #|  command = echo $out > $out
      #|build foo.cpp.obj: echo foo.cpp || foo.cpp
      #|  pool = compile
      #|build bar.cpp.obj: echo bar.cpp || bar.cpp
      #|  pool = compile
      #|build libfoo.a: echo foo.cpp.obj bar.cpp.obj
      #|build foo.cpp: gen_foo
      #|build bar.cpp: gen_bar
      #|build all: phony libfoo.a
      #|
    ),
  )
  f.dirty([
    "foo.cpp", "foo.cpp.obj", "bar.cpp", "bar.cpp.obj", "libfoo.a", "all",
  ])
  f.prepare_for_target("all")
  let initial = f.find_work_sorted(2)
  // foo first.
  assert_eq(initial[1].outputs()[0].path(), "foo.cpp")
  f.finish(initial[1])
  let inputs = fn(edge : @moonja.Edge) { edge.inputs().map(fn(n) { n.path() }) }
  let edge = f.work()
  assert_true(f.plan.find_work() is None)
  assert_eq(inputs(edge), ["foo.cpp", "foo.cpp"])
  assert_eq(edge.outputs()[0].path(), "foo.cpp.obj")
  f.finish(edge)
  // Now bar.
  assert_eq(initial[0].outputs()[0].path(), "bar.cpp")
  f.finish(initial[0])
  let edge = f.work()
  assert_true(f.plan.find_work() is None)
  assert_eq(inputs(edge), ["bar.cpp", "bar.cpp"])
  assert_eq(edge.outputs()[0].path(), "bar.cpp.obj")
  f.finish(edge)
  let edge = f.work()
  assert_true(f.plan.find_work() is None)
  assert_eq(inputs(edge), ["foo.cpp.obj", "bar.cpp.obj"])
  assert_eq(edge.outputs()[0].path(), "libfoo.a")
  f.finish(edge)
  let edge = f.work()
  assert_true(f.plan.find_work() is None)
  assert_eq(inputs(edge), ["libfoo.a"])
  assert_eq(edge.outputs()[0].path(), "all")
  f.finish(edge)
  assert_true(f.plan.find_work() is None)
  assert_false(f.plan.more_to_do())
}

///|
test "PlanTest.PoolWithFailingEdge" {
  let f = plan_fixture(
    "pool foobar\n  depth = 1\nrule poolcat\n  command = cat $in > $out\n  pool = foobar\nbuild out1: poolcat in\nbuild out2: poolcat in\n",
  )
  f.dirty(["out1", "out2"])
  f.plan.add_target(f.state.get_node("out1", 0))
  f.plan.add_target(f.state.get_node("out2", 0))
  f.plan.prepare_queue()
  assert_true(f.plan.more_to_do())
  let edge = f.work()
  assert_eq(ends(edge), ("in", "out1"))
  // The pool serializes the edges.
  assert_true(f.plan.find_work() is None)
  f.finish(edge, result=EdgeFailed)
  let edge = f.work()
  assert_eq(ends(edge), ("in", "out2"))
  assert_true(f.plan.find_work() is None)
  f.finish(edge, result=EdgeFailed)
  // The jobs failed, so there is still work to do.
  assert_true(f.plan.more_to_do())
  assert_true(f.plan.find_work() is None)
}

///|
test "PlanTest.PriorityWithoutBuildLog" {
  // Without a build log the critical path weight is the graph depth:
  //   a2
  //   |
  //   a1  b1
  //   |  |  |
  //   a0 b0 c0
  //    \ | /
  //     out
  let f = plan_fixture(
    "rule r\n  command = unused\nbuild out: r a0 b0 c0\nbuild a0: r a1\nbuild a1: r a2\nbuild b0: r b1\nbuild c0: r b1\n",
  )
  f.dirty(["a1", "a0", "b0", "c0", "out"])
  f.prepare_for_target("out")
  let weight = fn(path : String) {
    f.state.get_node(path, 0).in_edge().unwrap().critical_path_weight()
  }
  assert_eq(
    (weight("out"), weight("a0"), weight("b0"), weight("c0"), weight("a1")),
    (1, 2, 2, 2, 3),
  )
  for expected in ["a1", "a0", "b0", "c0", "out"] {
    let edge = f.work()
    assert_eq(edge.outputs()[0].path(), expected)
    f.finish(edge)
  }
  assert_true(f.plan.find_work() is None)
}
