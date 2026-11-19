// Ported from ninja v1.13.2 src/clparser_test.cc and
// src/includes_normalize_test.cc (Apache-2.0, see NOTICE). The Windows
// tests run everywhere: the working directory is given, not asked for.

///|
test "CLParserTest.ShowIncludes" {
  assert_eq(@moonja.filter_show_includes("", ""), "")
  assert_eq(@moonja.filter_show_includes("Sample compiler output", ""), "")
  assert_eq(
    @moonja.filter_show_includes(
      "Note: including file: c:\\Some Files\\foobar.h", "",
    ),
    "c:\\Some Files\\foobar.h",
  )
  assert_eq(
    @moonja.filter_show_includes(
      "Note: including file:    c:\\initspaces.h", "",
    ),
    "c:\\initspaces.h",
  )
  assert_eq(
    @moonja.filter_show_includes(
      "Non-default prefix: inc file:    c:\\initspaces.h", "Non-default prefix: inc file:",
    ),
    "c:\\initspaces.h",
  )
}

///|
test "CLParserTest.FilterInputFilename" {
  assert_true(@moonja.filter_input_filename("foobar.cc"))
  assert_true(@moonja.filter_input_filename("foo bar.cc"))
  assert_true(@moonja.filter_input_filename("baz.c"))
  assert_true(@moonja.filter_input_filename("FOOBAR.CC"))
  assert_false(
    @moonja.filter_input_filename(
      "src\\cl_helper.cc(166) : fatal error C1075: end of file found ...",
    ),
  )
}

///|
test "CLParserTest.ParseSimple" {
  let parsed = @moonja.parse_cl_output(
    "foo\r\nNote: inc file prefix:  foo.h\r\nbar\r\n", "Note: inc file prefix:",
  )
  assert_eq(parsed.filtered(), "foo\nbar\n")
  assert_eq(parsed.includes(), ["foo.h"])
}

///|
test "CLParserTest.ParseFilenameFilter" {
  let parsed = @moonja.parse_cl_output("foo.cc\r\ncl: warning\r\n", "")
  assert_eq(parsed.filtered(), "cl: warning\n")
}

///|
test "CLParserTest.NoFilenameFilterAfterShowIncludes" {
  let parsed = @moonja.parse_cl_output(
    "foo.cc\r\nNote: including file: foo.h\r\nsomething something foo.cc\r\n", "",
  )
  assert_eq(parsed.filtered(), "something something foo.cc\n")
}

///|
test "CLParserTest.ParseSystemInclude" {
  let parsed = @moonja.parse_cl_output(
    "Note: including file: c:\\Program Files\\foo.h\r\nNote: including file: d:\\Microsoft Visual Studio\\bar.h\r\nNote: including file: path.h\r\n",
    "",
  )
  // The first two look like system headers.
  assert_eq(parsed.filtered(), "")
  assert_eq(parsed.includes(), ["path.h"])
}

///|
test "CLParserTest.DuplicatedHeader" {
  let parsed = @moonja.parse_cl_output(
    "Note: including file: foo.h\r\nNote: including file: bar.h\r\nNote: including file: foo.h\r\n",
    "",
  )
  assert_eq(parsed.filtered(), "")
  assert_eq(parsed.includes().length(), 2)
}

///|
test "CLParserTest.DuplicatedHeaderPathConverted" {
  // POSIX: sub/./foo.h and sub/foo.h are one header.
  let parsed = @moonja.parse_cl_output(
    "Note: including file: sub/./foo.h\r\nNote: including file: bar.h\r\nNote: including file: sub/foo.h\r\n",
    "",
  )
  assert_eq(parsed.filtered(), "")
  assert_eq(parsed.includes().length(), 2)
  // Windows: so are sub/./foo.h and sub\foo.h.
  let parsed = @moonja.parse_cl_output(
    "Note: including file: sub/./foo.h\r\nNote: including file: bar.h\r\nNote: including file: sub\\foo.h\r\n",
    "",
    normalizer=@moonja.IncludesNormalize::new(".", test_cwd),
  )
  assert_eq(parsed.filtered(), "")
  assert_eq(parsed.includes().length(), 2)
}

///|
/// The working directory of the IncludesNormalize tests.
let test_cwd : String = "C:\\work\\proj"

///|
fn normalize_relative(
  input : String,
  relative_to : String,
) -> String raise @moonja.NinjaError {
  @moonja.IncludesNormalize::new(relative_to, test_cwd).normalize(input)
}

///|
fn normalize(input : String) -> String raise @moonja.NinjaError {
  normalize_relative(input, ".")
}

///|
test "IncludesNormalize.Simple" {
  assert_eq(normalize("a\\..\\b"), "b")
  assert_eq(normalize("a\\../b"), "b")
  assert_eq(normalize("a\\.\\b"), "a/b")
  assert_eq(normalize("a\\./b"), "a/b")
}

///|
test "IncludesNormalize.WithRelative" {
  let current_dir = "proj"
  assert_eq(normalize_relative("a/b/c", "a/b"), "c")
  assert_eq(normalize(@moonja.IncludesNormalize::abs_path("a", test_cwd)), "a")
  assert_eq(normalize_relative("a", "../b"), "../\{current_dir}/a")
  assert_eq(normalize_relative("a/b", "../c"), "../\{current_dir}/a/b")
  assert_eq(normalize_relative("a", "b/c"), "../../a")
  assert_eq(normalize_relative("a", "a"), ".")
}

///|
test "IncludesNormalize.Case" {
  assert_eq(normalize("Abc\\..\\b"), "b")
  assert_eq(normalize("Abc\\..\\BdEf"), "BdEf")
  assert_eq(normalize("A\\.\\b"), "A/b")
  assert_eq(normalize("a\\./b"), "a/b")
  assert_eq(normalize("A\\.\\B"), "A/B")
  assert_eq(normalize("A\\./B"), "A/B")
}

///|
test "IncludesNormalize.DifferentDrive" {
  assert_eq(normalize_relative("p:\\vs08\\stuff.h", "p:\\vs08"), "stuff.h")
  assert_eq(normalize_relative("P:\\Vs08\\stuff.h", "p:\\vs08"), "stuff.h")
  assert_eq(
    normalize_relative("p:\\vs08\\stuff.h", "c:\\vs08"),
    "p:/vs08/stuff.h",
  )
  assert_eq(
    normalize_relative("P:\\vs08\\stufF.h", "D:\\stuff/things"),
    "P:/vs08/stufF.h",
  )
  assert_eq(
    normalize_relative("P:/vs08\\stuff.h", "D:\\stuff/things"),
    "P:/vs08/stuff.h",
  )
  assert_eq(
    normalize_relative("P:/vs08\\../wee\\stuff.h", "D:\\stuff/things"),
    "P:/wee/stuff.h",
  )
}

///|
test "IncludesNormalize.LongInvalidPath" {
  let long_input = "C:\\Program Files (x86)\\Microsoft Visual Studio 12.0\\VC\\INCLUDEwarning #31001: The dll for reading and writing the pdb (for example, mspdb110.dll) could not be found on your path. This is usually a configuration error. Compilation will continue using /Z7 instead of /Zi, but expect a similar error when you link your program."
  // Too long to canonicalize; must fail cleanly.
  let message = try {
    ignore(normalize(long_input))
    ""
  } catch {
    error => error.message()
  }
  assert_true(message.contains("path too long"))
  // A path of exactly MAX_PATH under the working directory.
  let max_path = 260
  let cwd_len = test_cwd.length()
  let path = StringBuilder()
  path.write_string(test_cwd)
  path.write_string("\\a\\a")
  for i in (cwd_len + 4)..<max_path {
    if i > cwd_len + 4 && i < max_path - 1 && i % 10 == 0 {
      path.write_char('\\')
    } else {
      path.write_char('a')
    }
  }
  let exact = path.to_string()
  assert_eq(exact.length(), max_path)
  let forward = exact.replace_all(old="\\", new="/")
  assert_eq(
    normalize(exact),
    forward.unsafe_substring(start=cwd_len + 1, end=forward.length()),
  )
}

///|
test "IncludesNormalize.ShortRelativeButTooLongAbsolutePath" {
  assert_eq(normalize("a"), "a")
  // A relative path of exactly MAX_PATH: too long once made absolute.
  let path = StringBuilder()
  for i in 0..<260 {
    if i < 259 && i % 10 == 4 {
      path.write_char('\\')
    } else {
      path.write_char('a')
    }
  }
  let message = try {
    ignore(normalize(path.to_string()))
    ""
  } catch {
    error => error.message()
  }
  assert_true(message.contains("GetFullPathName"))
}
