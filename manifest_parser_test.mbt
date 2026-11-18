// Ported from ninja v1.13.2 src/manifest_parser_test.cc (Apache-2.0, see
// NOTICE). Test names follow the original; `#ifdef _WIN32` tests run with
// `Platform::Windows`.

///|
/// ninja's VirtualFileSystem, as far as the parser uses it.
struct VirtualFileSystem {
  files : Map[String, String]
  files_read : Array[String]
}

///|
fn VirtualFileSystem::new() -> VirtualFileSystem {
  { files: Map([]), files_read: [], }
}

///|
fn VirtualFileSystem::create(
  self : VirtualFileSystem,
  path : String,
  contents : String,
) -> Unit {
  self.files[path] = contents
}

///|
impl @moonja.FileReader for VirtualFileSystem with fn read_file(self, path) {
  self.files_read.push(path)
  match self.files.get(path) {
    Some(contents) => contents
    None => raise @moonja.Error("No such file or directory")
  }
}

///|
/// ninja's VerifyGraph: every edge has outputs, and the graph links agree.
fn verify_graph(state : @moonja.State) -> Unit raise {
  for edge in state.edges() {
    assert_true(!edge.outputs().is_empty())
    for input in edge.inputs() {
      assert_true(
        input.out_edges().iter().any(fn(e) { physical_equal(e, edge) }),
      )
    }
    for output in edge.outputs() {
      guard output.in_edge() is Some(in_edge) else {
        fail("output without in-edge")
      }
      assert_true(physical_equal(in_edge, edge))
    }
  }
}

///|
fn parse_with(
  state : @moonja.State,
  fs : VirtualFileSystem,
  input : String,
  options~ : @moonja.ManifestParserOptions = @moonja.ManifestParserOptions::default(),
) -> String {
  let parser = @moonja.ManifestParser::new(state, reader=fs, options~)
  try {
    parser.parse_test(input)
    ""
  } catch {
    error => error.message()
  }
}

///|
/// ParserTest::AssertParse.
fn assert_parse(
  state : @moonja.State,
  fs : VirtualFileSystem,
  input : String,
) -> Unit raise {
  assert_eq(parse_with(state, fs, input), "")
  verify_graph(state)
}

///|
/// Parses into a fresh state without a file system, returning the error.
fn parse_error(input : String) -> String {
  let parser = @moonja.ManifestParser::without_files(@moonja.State::new())
  try {
    parser.parse_test(input)
    ""
  } catch {
    error => error.message()
  }
}

///|
fn first_rule(state : @moonja.State) -> @moonja.Rule {
  state.bindings().rules()[0]
}

///|
fn command(rule : @moonja.Rule) -> String {
  rule.get_binding("command").unwrap().serialize()
}

///|
fn edge_of(state : @moonja.State, path : String) -> @moonja.Edge {
  state.lookup_node(path).unwrap().in_edge().unwrap()
}

///|
test "ParserTest.Empty" {
  assert_parse(@moonja.State::new(), VirtualFileSystem::new(), "")
}

///|
test "ParserTest.Rules" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|
      #|rule date
      #|  command = date > $out
      #|
      #|build result: cat in_1.cc in-2.O
      #|
    ),
  )
  assert_eq(state.bindings().rules().length(), 3)
  let rule = first_rule(state)
  assert_eq(rule.name(), "cat")
  assert_eq(command(rule), "[cat ][$in][ > ][$out]")
}

///|
test "ParserTest.RuleAttributes" {
  assert_parse(
    @moonja.State::new(),
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = a
      #|  depfile = a
      #|  deps = a
      #|  description = a
      #|  generator = a
      #|  restat = a
      #|  rspfile = a
      #|  rspfile_content = a
      #|
    ),
  )
}

///|
test "ParserTest.IgnoreIndentedComments" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|  #indented comment
      #|rule cat
      #|  command = cat $in > $out
      #|  #generator = 1
      #|  restat = 1 # comment
      #|  #comment
      #|build result: cat in_1.cc in-2.O
      #|  #comment
      #|
    ),
  )
  assert_eq(state.bindings().rules().length(), 2)
  assert_eq(first_rule(state).name(), "cat")
  let edge = state.get_node("result", 0).in_edge().unwrap()
  assert_true(edge.get_binding_bool("restat"))
  assert_false(edge.get_binding_bool("generator"))
}

///|
test "ParserTest.IgnoreIndentedBlankLines" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "  \nrule cat\n  command = cat $in > $out\n  \nbuild result: cat in_1.cc in-2.O\n  \nvariable=1\n",
  )
  // The variable must be in the top-level scope.
  assert_eq(state.bindings().lookup("variable"), "1")
}

///|
test "ParserTest.ResponseFiles" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat_rsp
      #|  command = cat $rspfile > $out
      #|  rspfile = $rspfile
      #|  rspfile_content = $in
      #|
      #|build out: cat_rsp in
      #|  rspfile=out.rsp
      #|
    ),
  )
  assert_eq(state.bindings().rules().length(), 2)
  let rule = first_rule(state)
  assert_eq(rule.name(), "cat_rsp")
  assert_eq(command(rule), "[cat ][$rspfile][ > ][$out]")
  assert_eq(rule.get_binding("rspfile").unwrap().serialize(), "[$rspfile]")
  assert_eq(rule.get_binding("rspfile_content").unwrap().serialize(), "[$in]")
}

///|
test "ParserTest.InNewline" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat_rsp
      #|  command = cat $in_newline > $out
      #|
      #|build out: cat_rsp in in2
      #|  rspfile=out.rsp
      #|
    ),
  )
  assert_eq(state.bindings().rules().length(), 2)
  let rule = first_rule(state)
  assert_eq(rule.name(), "cat_rsp")
  assert_eq(command(rule), "[cat ][$in_newline][ > ][$out]")
  assert_eq(state.edges()[0].evaluate_command(), "cat in\nin2 > out")
}

///|
test "ParserTest.Variables" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|l = one-letter-test
      #|rule link
      #|  command = ld $l $extra $with_under -o $out $in
      #|
      #|extra = -pthread
      #|with_under = -under
      #|build a: link b c
      #|nested1 = 1
      #|nested2 = $nested1/2
      #|build supernested: link x
      #|  extra = $nested2/3
      #|
    ),
  )
  assert_eq(state.edges().length(), 2)
  assert_eq(
    state.edges()[0].evaluate_command(),
    "ld one-letter-test -pthread -under -o a b c",
  )
  assert_eq(state.bindings().lookup("nested2"), "1/2")
  assert_eq(
    state.edges()[1].evaluate_command(),
    "ld one-letter-test 1/2/3 -under -o supernested x",
  )
}

///|
test "ParserTest.VariableScope" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|foo = bar
      #|rule cmd
      #|  command = cmd $foo $in $out
      #|
      #|build inner: cmd a
      #|  foo = baz
      #|build outer: cmd b
      #|
      #|
    ),
  )
  assert_eq(state.edges().length(), 2)
  assert_eq(state.edges()[0].evaluate_command(), "cmd baz a inner")
  assert_eq(state.edges()[1].evaluate_command(), "cmd bar b outer")
}

///|
test "ParserTest.Continuation" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule link
      #|  command = foo bar $
      #|    baz
      #|
      #|build a: link c $
      #| d e f
      #|
    ),
  )
  assert_eq(state.bindings().rules().length(), 2)
  let rule = first_rule(state)
  assert_eq(rule.name(), "link")
  assert_eq(command(rule), "[foo bar baz]")
}

///|
test "ParserTest.Backslash" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "foo = bar\\baz\nfoo2 = bar\\ baz\n",
  )
  assert_eq(state.bindings().lookup("foo"), "bar\\baz")
  assert_eq(state.bindings().lookup("foo2"), "bar\\ baz")
}

///|
test "ParserTest.Comment" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "# this is a comment\nfoo = not # a comment\n",
  )
  assert_eq(state.bindings().lookup("foo"), "not # a comment")
}

///|
test "ParserTest.Dollars" {
  let input =
    #|rule foo
    #|  command = ${out}bar$$baz$$$
    #|blah
    #|x = $$dollar
    #|build $x: foo y
    #|
  let state = @moonja.State::new()
  assert_parse(state, VirtualFileSystem::new(), input)
  assert_eq(state.bindings().lookup("x"), "$dollar")
  assert_eq(state.edges()[0].evaluate_command(), "'$dollar'bar$baz$blah")
  let windows = @moonja.State::new(platform=Windows)
  assert_parse(windows, VirtualFileSystem::new(), input)
  assert_eq(windows.edges()[0].evaluate_command(), "$dollarbar$baz$blah")
}

///|
test "ParserTest.EscapeSpaces" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule spaces
      #|  command = something
      #|build foo$ bar: spaces $$one two$$$ three
      #|
    ),
  )
  assert_true(state.lookup_node("foo bar") is Some(_))
  let edge = state.edges()[0]
  assert_eq(edge.outputs()[0].path(), "foo bar")
  assert_eq(edge.inputs()[0].path(), "$one")
  assert_eq(edge.inputs()[1].path(), "two$ three")
  assert_eq(edge.evaluate_command(), "something")
}

///|
test "ParserTest.CanonicalizeFile" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build out: cat in/1 in//2
      #|build in/1: cat
      #|build in/2: cat
      #|
    ),
  )
  assert_true(state.lookup_node("in/1") is Some(_))
  assert_true(state.lookup_node("in/2") is Some(_))
  assert_true(state.lookup_node("in//1") is None)
  assert_true(state.lookup_node("in//2") is None)
}

///|
test "ParserTest.CanonicalizeFileBackslashes" {
  let state = @moonja.State::new(platform=Windows)
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build out: cat in\1 in\\2
      #|build in\1: cat
      #|build in\2: cat
      #|
    ),
  )
  assert_eq(state.lookup_node("in/1").unwrap().slash_bits(), 1)
  assert_eq(state.lookup_node("in/2").unwrap().slash_bits(), 1)
  assert_true(state.lookup_node("in//1") is None)
  assert_true(state.lookup_node("in//2") is None)
}

///|
test "ParserTest.PathVariables" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|dir = out
      #|build $dir/exe: cat src
      #|
    ),
  )
  assert_true(state.lookup_node("$dir/exe") is None)
  assert_true(state.lookup_node("out/exe") is Some(_))
}

///|
test "ParserTest.CanonicalizePaths" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build ./out.o: cat ./bar/baz/../foo.cc
      #|
    ),
  )
  assert_true(state.lookup_node("./out.o") is None)
  assert_true(state.lookup_node("out.o") is Some(_))
  assert_true(state.lookup_node("./bar/baz/../foo.cc") is None)
  assert_true(state.lookup_node("bar/foo.cc") is Some(_))
}

///|
test "ParserTest.CanonicalizePathsBackslashes" {
  let state = @moonja.State::new(platform=Windows)
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build ./out.o: cat ./bar/baz/../foo.cc
      #|build .\out2.o: cat .\bar/baz\..\foo.cc
      #|build .\out3.o: cat .\bar\baz\..\foo3.cc
      #|
    ),
  )
  assert_true(state.lookup_node("./out.o") is None)
  assert_true(state.lookup_node(".\\out2.o") is None)
  assert_true(state.lookup_node(".\\out3.o") is None)
  assert_true(state.lookup_node("out.o") is Some(_))
  assert_true(state.lookup_node("out2.o") is Some(_))
  assert_true(state.lookup_node("out3.o") is Some(_))
  assert_true(state.lookup_node("./bar/baz/../foo.cc") is None)
  assert_true(state.lookup_node(".\\bar/baz\\..\\foo.cc") is None)
  assert_true(state.lookup_node(".\\bar/baz\\..\\foo3.cc") is None)
  assert_eq(state.lookup_node("bar/foo.cc").unwrap().slash_bits(), 0)
  assert_eq(state.lookup_node("bar/foo3.cc").unwrap().slash_bits(), 1)
}

///|
test "ParserTest.DuplicateEdgeWithMultipleOutputsError" {
  let error = parse_with(
    @moonja.State::new(),
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build out1 out2: cat in1
      #|build out1: cat in2
      #|build final: cat out1
      #|
    ),
  )
  assert_eq(error, "input:5: multiple rules generate out1\n")
}

///|
test "ParserTest.DuplicateEdgeInIncludedFile" {
  let fs = VirtualFileSystem::new()
  fs.create(
    "sub.ninja",
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build out1 out2: cat in1
      #|build out1: cat in2
      #|build final: cat out1
      #|
    ),
  )
  let error = parse_with(@moonja.State::new(), fs, "subninja sub.ninja\n")
  assert_eq(error, "sub.ninja:5: multiple rules generate out1\n")
}

///|
test "ParserTest.PhonySelfReferenceIgnored" {
  let state = @moonja.State::new()
  assert_parse(state, VirtualFileSystem::new(), "build a: phony a\n")
  assert_true(edge_of(state, "a").inputs().is_empty())
}

///|
test "ParserTest.PhonySelfReferenceKept" {
  let state = @moonja.State::new()
  let error = parse_with(
    state,
    VirtualFileSystem::new(),
    "build a: phony a\n",
    options={ phony_cycle_action: Error, },
  )
  assert_eq(error, "")
  let node = state.lookup_node("a").unwrap()
  let edge = node.in_edge().unwrap()
  assert_eq(edge.inputs().length(), 1)
  assert_true(physical_equal(edge.inputs()[0], node))
}

///|
test "ParserTest.ReservedWords" {
  assert_parse(
    @moonja.State::new(),
    VirtualFileSystem::new(),
    (
      #|rule build
      #|  command = rule run $out
      #|build subninja: build include default foo.cc
      #|default subninja
      #|
    ),
  )
}

///|
test "ParserTest.Errors" {
  let cases : Array[(String, String)] = [
    ("subn", "input:1: expected '=', got eof\nsubn\n    ^ near here"),
    ("foobar", "input:1: expected '=', got eof\nfoobar\n      ^ near here"),
    ("x 3", "input:1: expected '=', got identifier\nx 3\n  ^ near here"),
    ("x = 3", "input:1: unexpected EOF\nx = 3\n     ^ near here"),
    ("x = 3\ny 2", "input:2: expected '=', got identifier\ny 2\n  ^ near here"),
    (
      "x = $", "input:1: bad $-escape (literal $ must be written as $$)\nx = $\n    ^ near here",
    ),
    (
      "x = $\n $[\n", "input:2: bad $-escape (literal $ must be written as $$)\n $[\n ^ near here",
    ),
    ("x = a$\n b$\n $\n", "input:4: unexpected EOF\n"),
    ("build\n", "input:1: expected path\nbuild\n     ^ near here"),
    (
      "build x: y z\n", "input:1: unknown build rule 'y'\nbuild x: y z\n         ^ near here",
    ),
    (
      "build x:: y z\n", "input:1: expected build command name\nbuild x:: y z\n        ^ near here",
    ),
    (
      "rule cat\n  command = cat ok\nbuild x: cat $\n :\n", "input:4: expected newline, got ':'\n :\n ^ near here",
    ),
    ("rule cat\n", "input:2: expected 'command =' line\n"),
    (
      "rule cat\n  command = echo\nrule cat\n  command = echo\n", "input:3: duplicate rule 'cat'\nrule cat\n        ^ near here",
    ),
    (
      "rule cat\n  command = echo\n  rspfile = cat.rsp\n", "input:4: rspfile and rspfile_content need to be both specified\n",
    ),
    (
      "rule cat\n  command = ${fafsd\nfoo = bar\n", "input:2: bad $-escape (literal $ must be written as $$)\n  command = ${fafsd\n            ^ near here",
    ),
    (
      "rule cat\n  command = cat\nbuild $.: cat foo\n", "input:3: bad $-escape (literal $ must be written as $$)\nbuild $.: cat foo\n      ^ near here",
    ),
    (
      "rule cat\n  command = cat\nbuild $: cat foo\n", "input:3: expected ':', got newline ($ also escapes ':')\nbuild $: cat foo\n                ^ near here",
    ),
    ("rule %foo\n", "input:1: expected rule name\nrule %foo\n     ^ near here"),
    (
      "rule cc\n  command = foo\n  othervar = bar\n", "input:3: unexpected variable 'othervar'\n  othervar = bar\n                ^ near here",
    ),
    (
      "rule cc\n  command = foo\nbuild $.: cc bar.cc\n", "input:3: bad $-escape (literal $ must be written as $$)\nbuild $.: cc bar.cc\n      ^ near here",
    ),
    (
      "rule cc\n  command = foo\n  && bar", "input:3: expected variable name\n  && bar\n  ^ near here",
    ),
    (
      "rule cc\n  command = foo\nbuild $: cc bar.cc\n", "input:3: expected ':', got newline ($ also escapes ':')\nbuild $: cc bar.cc\n                  ^ near here",
    ),
    ("default\n", "input:1: expected target name\ndefault\n       ^ near here"),
    (
      "default nonexistent\n", "input:1: unknown target 'nonexistent'\ndefault nonexistent\n                   ^ near here",
    ),
    (
      "rule r\n  command = r\nbuild b: r\ndefault b:\n", "input:4: expected newline, got ':'\ndefault b:\n         ^ near here",
    ),
    ("default $a\n", "input:1: empty path\ndefault $a\n          ^ near here"),
    // ninja's own comment: the line number is wrong, because paths are
    // evaluated after the whole statement has been read.
    ("rule r\n  command = r\nbuild $a: r $c\n", "input:4: empty path\n"),
    // An indented blank line ends the rule.
    (
      "rule r\n  command = r\n  \n  generator = 1\n", "input:4: unexpected indent\n",
    ),
    ("pool\n", "input:1: expected pool name\npool\n    ^ near here"),
    ("pool foo\n", "input:2: expected 'depth =' line\n"),
    (
      "pool foo\n  depth = 4\npool foo\n", "input:3: duplicate pool 'foo'\npool foo\n        ^ near here",
    ),
    (
      "pool foo\n  depth = -1\n", "input:2: invalid pool depth\n  depth = -1\n            ^ near here",
    ),
    (
      "pool foo\n  bar = 1\n", "input:2: unexpected variable 'bar'\n  bar = 1\n         ^ near here",
    ),
    // Pool names are looked up when the edge is parsed.
    (
      "rule run\n  command = echo\n  pool = unnamed_pool\nbuild out: run in\n", "input:5: unknown pool name 'unnamed_pool'\n",
    ),
  ]
  for case in cases {
    let (input, expected) = case
    assert_eq(parse_error(input), expected, msg="input: \{input}")
  }
}

///|
test "ParserTest.MissingInput" {
  let parser = @moonja.ManifestParser::new(
    @moonja.State::new(),
    reader=VirtualFileSystem::new(),
  )
  let error = try {
    parser.load("build.ninja")
    ""
  } catch {
    error => error.message()
  }
  assert_eq(error, "loading 'build.ninja': No such file or directory")
}

///|
test "ParserTest.MultipleOutputs" {
  assert_eq(
    parse_error(
      "rule cc\n  command = foo\n  depfile = bar\nbuild a.o b.o: cc c.cc\n",
    ),
    "",
  )
}

///|
test "ParserTest.MultipleOutputsWithDeps" {
  assert_eq(
    parse_error(
      "rule cc\n  command = foo\n  deps = gcc\nbuild a.o b.o: cc c.cc\n",
    ),
    "",
  )
}

///|
test "ParserTest.SubNinja" {
  let fs = VirtualFileSystem::new()
  fs.create("test.ninja", "var = inner\nbuild $builddir/inner: varref\n")
  let state = @moonja.State::new()
  assert_parse(
    state,
    fs,
    (
      #|builddir = some_dir/
      #|rule varref
      #|  command = varref $var
      #|var = outer
      #|build $builddir/outer: varref
      #|subninja test.ninja
      #|build $builddir/outer2: varref
      #|
    ),
  )
  assert_eq(fs.files_read, ["test.ninja"])
  assert_true(state.lookup_node("some_dir/outer") is Some(_))
  // builddir is inherited by the subninja.
  assert_true(state.lookup_node("some_dir/inner") is Some(_))
  assert_eq(state.edges().length(), 3)
  assert_eq(state.edges()[0].evaluate_command(), "varref outer")
  assert_eq(state.edges()[1].evaluate_command(), "varref inner")
  assert_eq(state.edges()[2].evaluate_command(), "varref outer")
}

///|
test "ParserTest.MissingSubNinja" {
  let error = parse_with(
    @moonja.State::new(),
    VirtualFileSystem::new(),
    "subninja foo.ninja\n",
  )
  assert_eq(
    error, "input:1: loading 'foo.ninja': No such file or directory\nsubninja foo.ninja\n                  ^ near here",
  )
}

///|
test "ParserTest.DuplicateRuleInDifferentSubninjas" {
  // Rules are scoped to subninjas.
  let fs = VirtualFileSystem::new()
  fs.create("test.ninja", "rule cat\n  command = cat\n")
  assert_eq(
    parse_with(
      @moonja.State::new(),
      fs,
      "rule cat\n  command = cat\nsubninja test.ninja\n",
    ),
    "",
  )
}

///|
test "ParserTest.DuplicateRuleInDifferentSubninjasWithInclude" {
  // Rules are scoped to subninjas even with includes.
  let fs = VirtualFileSystem::new()
  fs.create("rules.ninja", "rule cat\n  command = cat\n")
  fs.create("test.ninja", "include rules.ninja\nbuild x : cat\n")
  assert_eq(
    parse_with(
      @moonja.State::new(),
      fs,
      "include rules.ninja\nsubninja test.ninja\nbuild y : cat\n",
    ),
    "",
  )
}

///|
test "ParserTest.Include" {
  let fs = VirtualFileSystem::new()
  fs.create("include.ninja", "var = inner\n")
  let state = @moonja.State::new()
  assert_parse(state, fs, "var = outer\ninclude include.ninja\n")
  assert_eq(fs.files_read, ["include.ninja"])
  assert_eq(state.bindings().lookup("var"), "inner")
}

///|
test "ParserTest.BrokenInclude" {
  let fs = VirtualFileSystem::new()
  fs.create("include.ninja", "build\n")
  assert_eq(
    parse_with(@moonja.State::new(), fs, "include include.ninja\n"),
    "include.ninja:1: expected path\nbuild\n     ^ near here",
  )
}

///|
test "ParserTest.Implicit" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild foo: cat bar | baz\n",
  )
  assert_true(edge_of(state, "foo").is_implicit(1))
}

///|
test "ParserTest.OrderOnly" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild foo: cat bar || baz\n",
  )
  assert_true(edge_of(state, "foo").is_order_only(1))
}

///|
test "ParserTest.Validations" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild foo: cat bar |@ baz\n",
  )
  let edge = edge_of(state, "foo")
  assert_eq(edge.validations().length(), 1)
  assert_eq(edge.validations()[0].path(), "baz")
}

///|
test "ParserTest.ImplicitOutput" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild foo | imp: cat bar\n",
  )
  let edge = edge_of(state, "imp")
  assert_eq(edge.outputs().length(), 2)
  assert_true(edge.is_implicit_out(1))
}

///|
test "ParserTest.ImplicitOutputEmpty" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild foo | : cat bar\n",
  )
  let edge = edge_of(state, "foo")
  assert_eq(edge.outputs().length(), 1)
  assert_false(edge.is_implicit_out(0))
}

///|
test "ParserTest.ImplicitOutputDupeError" {
  assert_eq(
    parse_error(
      "rule cat\n  command = cat $in > $out\nbuild foo baz | foo baq foo: cat bar\n",
    ),
    "input:4: foo is defined as an output multiple times\n",
  )
}

///|
test "ParserTest.ImplicitOutputDupesError" {
  assert_eq(
    parse_error(
      "rule cat\n  command = cat $in > $out\nbuild foo foo foo | foo foo foo foo: cat bar\n",
    ),
    "input:4: foo is defined as an output multiple times\n",
  )
}

///|
test "ParserTest.NoExplicitOutput" {
  assert_eq(
    parse_error("rule cat\n  command = cat $in > $out\nbuild | imp : cat bar\n"),
    "",
  )
}

///|
test "ParserTest.DefaultDefault" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild a: cat foo\nbuild b: cat foo\nbuild c: cat foo\nbuild d: cat foo\n",
  )
  assert_eq(state.default_nodes().length(), 4)
}

///|
test "ParserTest.DefaultDefaultCycle" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild a: cat a\n",
  )
  let error = try {
    ignore(state.default_nodes())
    ""
  } catch {
    error => error.message()
  }
  assert_eq(error, "could not determine root nodes of build graph")
}

///|
test "ParserTest.DefaultStatements" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    (
      #|rule cat
      #|  command = cat $in > $out
      #|build a: cat foo
      #|build b: cat foo
      #|build c: cat foo
      #|build d: cat foo
      #|third = c
      #|default a b
      #|default $third
      #|
    ),
  )
  let nodes = state.default_nodes()
  assert_eq(nodes.map(fn(n) { n.path() }), ["a", "b", "c"])
}

///|
test "ParserTest.UTF8" {
  assert_parse(
    @moonja.State::new(),
    VirtualFileSystem::new(),
    "rule utf8\n  command = true\n  description = compilación\n",
  )
}

///|
test "ParserTest.CRLF" {
  assert_eq(parse_error("# comment with crlf\r\n"), "")
  assert_eq(parse_error("foo = foo\nbar = bar\r\n"), "")
  assert_eq(
    parse_error(
      "pool link_pool\r\n  depth = 15\r\n\r\nrule xyz\r\n  command = something$expand \r\n  description = YAY!\r\n",
    ),
    "",
  )
}

///|
test "ParserTest.DyndepNotSpecified" {
  let state = @moonja.State::new()
  assert_parse(
    state,
    VirtualFileSystem::new(),
    "rule cat\n  command = cat $in > $out\nbuild result: cat in\n",
  )
  assert_true(state.get_node("result", 0).in_edge().unwrap().dyndep() is None)
}

///|
test "ParserTest.DyndepNotInput" {
  assert_eq(
    parse_error(
      "rule touch\n  command = touch $out\nbuild result: touch\n  dyndep = notin\n",
    ),
    "input:5: dyndep 'notin' is not an input\n",
  )
}

///|
fn assert_dyndep(input : String, expected : String) -> Unit raise {
  let state = @moonja.State::new()
  assert_parse(state, VirtualFileSystem::new(), input)
  let dyndep = state.get_node("result", 0).in_edge().unwrap().dyndep().unwrap()
  assert_true(dyndep.dyndep_pending())
  assert_eq(dyndep.path(), expected)
}

///|
test "ParserTest.DyndepExplicitInput" {
  assert_dyndep(
    "rule cat\n  command = cat $in > $out\nbuild result: cat in\n  dyndep = in\n",
    "in",
  )
}

///|
test "ParserTest.DyndepImplicitInput" {
  assert_dyndep(
    "rule cat\n  command = cat $in > $out\nbuild result: cat in | dd\n  dyndep = dd\n",
    "dd",
  )
}

///|
test "ParserTest.DyndepOrderOnlyInput" {
  assert_dyndep(
    "rule cat\n  command = cat $in > $out\nbuild result: cat in || dd\n  dyndep = dd\n",
    "dd",
  )
}

///|
test "ParserTest.DyndepRuleInput" {
  assert_dyndep(
    "rule cat\n  command = cat $in > $out\n  dyndep = $in\nbuild result: cat in\n",
    "in",
  )
}
