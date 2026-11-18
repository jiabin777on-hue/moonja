// Ported from ninja v1.13.2 src/depfile_parser_test.cc (Apache-2.0, see
// NOTICE). Test names follow the original.

///|
fn depfile(input : String) -> (Array[String], Array[String]) raise {
  let parsed = @moonja.parse_depfile(input)
  (parsed.outs(), parsed.ins())
}

///|
fn depfile_error(input : String) -> String {
  try {
    ignore(@moonja.parse_depfile(input))
    ""
  } catch {
    error => error.message()
  }
}

///|
test "DepfileParserTest.Basic" {
  let (outs, ins) = depfile(
    "build/ninja.o: ninja.cc ninja.h eval_env.h manifest_parser.h\n",
  )
  assert_eq(outs, ["build/ninja.o"])
  assert_eq(ins.length(), 4)
}

///|
test "DepfileParserTest.EarlyNewlineAndWhitespace" {
  ignore(depfile(" \\\n  out: in\n"))
}

///|
test "DepfileParserTest.Continuation" {
  let (outs, ins) = depfile("foo.o: \\\n  bar.h baz.h\n")
  assert_eq(outs, ["foo.o"])
  assert_eq(ins.length(), 2)
}

///|
test "DepfileParserTest.WindowsDrivePaths" {
  let (outs, ins) = depfile("foo.o: //?/c:/bar.h\n")
  assert_eq(outs, ["foo.o"])
  assert_eq(ins, ["//?/c:/bar.h"])
}

///|
test "DepfileParserTest.AmpersandsAndQuotes" {
  let (outs, ins) = depfile(
    "foo&bar.o foo'bar.o foo\"bar.o: foo&bar.h foo'bar.h foo\"bar.h\n",
  )
  assert_eq(outs, ["foo&bar.o", "foo'bar.o", "foo\"bar.o"])
  assert_eq(ins, ["foo&bar.h", "foo'bar.h", "foo\"bar.h"])
}

///|
test "DepfileParserTest.CarriageReturnContinuation" {
  let (outs, ins) = depfile("foo.o: \\\r\n  bar.h baz.h\r\n")
  assert_eq(outs, ["foo.o"])
  assert_eq(ins.length(), 2)
}

///|
test "DepfileParserTest.BackSlashes" {
  let (outs, ins) = depfile(
    (
      #|Project\Dir\Build\Release8\Foo\Foo.res : \
      #|  Dir\Library\Foo.rc \
      #|  Dir\Library\Version\Bar.h \
      #|  Dir\Library\Foo.ico \
      #|  Project\Thing\Bar.tlb \
      #|
    ),
  )
  assert_eq(outs, ["Project\\Dir\\Build\\Release8\\Foo\\Foo.res"])
  assert_eq(ins.length(), 4)
}

///|
test "DepfileParserTest.Spaces" {
  let (outs, ins) = depfile("a\\ bc\\ def:   a\\ b c d")
  assert_eq(outs, ["a bc def"])
  assert_eq(ins, ["a b", "c", "d"])
}

///|
test "DepfileParserTest.MultipleBackslashes" {
  // 2N+1 backslashes and a space become N backslashes and the space; a
  // backslash before # is removed; other backslashes stay, including 2N
  // backslashes before a space.
  let (outs, ins) = depfile(
    "a\\ b\\#c.h: \\\\\\\\\\  \\\\\\\\ \\\\share\\info\\\\#1",
  )
  assert_eq(outs, ["a b#c.h"])
  assert_eq(ins, ["\\\\ ", "\\\\\\\\", "\\\\share\\info\\#1"])
}

///|
test "DepfileParserTest.Escapes" {
  // Which backslash escapes make it through.
  let (outs, ins) = depfile("\\!\\@\\#$$\\%\\^\\&\\[\\]\\\\:")
  assert_eq(outs, ["\\!\\@#$\\%\\^\\&\\[\\]\\\\"])
  assert_eq(ins, [])
}

///|
test "DepfileParserTest.EscapedColons" {
  // Depfiles from Clang, GCC before 10 and GCC 10 on Windows.
  // An escaped string keeps the trailing space of ninja's input, which
  // `moon fmt` would strip from a `#|` line.
  let (outs, ins) = depfile(
    "c\\:\\gcc\\x86_64-w64-mingw32\\include\\stddef.o: \\\n c:\\gcc\\x86_64-w64-mingw32\\include\\stddef.h \n",
  )
  assert_eq(outs, ["c:\\gcc\\x86_64-w64-mingw32\\include\\stddef.o"])
  assert_eq(ins, ["c:\\gcc\\x86_64-w64-mingw32\\include\\stddef.h"])
}

///|
test "DepfileParserTest.EscapedTargetColon" {
  let (outs, ins) = depfile("foo1\\: x\nfoo1\\:\nfoo1\\:\r\nfoo1\\:\t\nfoo1\\:")
  assert_eq(outs, ["foo1\\"])
  assert_eq(ins, ["x"])
}

///|
test "DepfileParserTest.SpecialChars" {
  // File names like istreambuf.iterator_op!= exist in libcxx's tests.
  let (outs, ins) = depfile(
    (
      #|C:/Program\ Files\ (x86)/Microsoft\ crtdefs.h: \
      #| en@quot.header~ t+t-x!=1 \
      #| openldap/slapd.d/cn=config/cn=schema/cn={0}core.ldif\
      #| Fußball\
      #| a[1]b@2%c
    ),
  )
  assert_eq(outs, ["C:/Program Files (x86)/Microsoft crtdefs.h"])
  assert_eq(ins, [
    "en@quot.header~", "t+t-x!=1", "openldap/slapd.d/cn=config/cn=schema/cn={0}core.ldif",
    "Fußball", "a[1]b@2%c",
  ])
}

///|
test "DepfileParserTest.UnifyMultipleOutputs" {
  let (outs, ins) = depfile("foo foo: x y z")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.MultipleDifferentOutputs" {
  let (outs, ins) = depfile("foo bar: x y z")
  assert_eq(outs, ["foo", "bar"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.MultipleEmptyRules" {
  let (outs, ins) = depfile("foo: x\nfoo: \nfoo:\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x"])
}

///|
test "DepfileParserTest.UnifyMultipleRulesLF" {
  let (outs, ins) = depfile("foo: x\nfoo: y\nfoo \\\nfoo: z\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.UnifyMultipleRulesCRLF" {
  let (outs, ins) = depfile("foo: x\r\nfoo: y\r\nfoo \\\r\nfoo: z\r\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.UnifyMixedRulesLF" {
  let (outs, ins) = depfile("foo: x\\\n     y\nfoo \\\nfoo: z\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.UnifyMixedRulesCRLF" {
  let (outs, ins) = depfile("foo: x\\\r\n     y\r\nfoo \\\r\nfoo: z\r\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.IndentedRulesLF" {
  let (outs, ins) = depfile(" foo: x\n foo: y\n foo: z\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.IndentedRulesCRLF" {
  let (outs, ins) = depfile(" foo: x\r\n foo: y\r\n foo: z\r\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.TolerateMP" {
  let (outs, ins) = depfile("foo: x y z\nx:\ny:\nz:\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.MultipleRulesTolerateMP" {
  let (outs, ins) = depfile("foo: x\nx:\nfoo: y\ny:\nfoo: z\nz:\n")
  assert_eq(outs, ["foo"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.MultipleRulesDifferentOutputs" {
  // Different outputs spread over several rules.
  let (outs, ins) = depfile("foo: x y\nbar: y z\n")
  assert_eq(outs, ["foo", "bar"])
  assert_eq(ins, ["x", "y", "z"])
}

///|
test "DepfileParserTest.BuggyMP" {
  assert_eq(
    depfile_error("foo: x y z\nx: alsoin\ny:\nz:\n"),
    "inputs may not also have inputs",
  )
}

///|
test "DepfileParserTest.EmptyFile" {
  assert_eq(depfile(""), ([], []))
}

///|
test "DepfileParserTest.EmptyLines" {
  assert_eq(depfile("\n\n"), ([], []))
}

///|
test "DepfileParserTest.MissingColon" {
  // Not empty, but without a colon.
  assert_eq(depfile_error("foo.o foo.c\n"), "expected ':' in depfile")
}
