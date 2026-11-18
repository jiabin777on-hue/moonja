// Ported from ninja v1.13.2 src/elide_middle_test.cc, the
// StripAnsiEscapeCodes cases of src/util_test.cc and the StatusFormat cases
// of src/build_test.cc (Apache-2.0, see NOTICE).

///|
/// A terminal that records what is written.
struct FakeTerminal {
  out : StringBuilder
  err : StringBuilder
  smart : Bool
  color : Bool
  width : Int32
}

///|
fn FakeTerminal::new(
  smart~ : Bool = false,
  color~ : Bool = false,
  width~ : Int32 = 0,
) -> FakeTerminal {
  { out: StringBuilder(), err: StringBuilder(), smart, color, width, }
}

///|
impl @moonja.Terminal for FakeTerminal with fn write_out(self, text) {
  self.out.write_string(text)
}

///|
impl @moonja.Terminal for FakeTerminal with fn write_command_output(self, text) {
  self.out.write_string(text)
}

///|
impl @moonja.Terminal for FakeTerminal with fn write_err(self, text) {
  self.err.write_string(text)
}

///|
impl @moonja.Terminal for FakeTerminal with fn is_smart(self) {
  self.smart
}

///|
impl @moonja.Terminal for FakeTerminal with fn supports_color(self) {
  self.color
}

///|
impl @moonja.Terminal for FakeTerminal with fn width(self) {
  self.width
}

///|
test "ElideMiddle.NothingToElide" {
  let input = "Nothing to elide in this short string."
  assert_eq(@moonja.elide_middle(input, 80), input)
  assert_eq(@moonja.elide_middle(input, 38), input)
  assert_eq(@moonja.elide_middle(input, 0), "")
  assert_eq(@moonja.elide_middle(input, 1), ".")
  assert_eq(@moonja.elide_middle(input, 2), "..")
  assert_eq(@moonja.elide_middle(input, 3), "...")
}

///|
test "ElideMiddle.ElideInTheMiddle" {
  let input = "01234567890123456789"
  let cases = [
    (4, "...9"),
    (5, "0...9"),
    (9, "012...789"),
    (10, "012...6789"),
    (11, "0123...6789"),
    (19, "01234567...23456789"),
    (20, "01234567890123456789"),
  ]
  for case in cases {
    assert_eq(@moonja.elide_middle(input, case.0), case.1)
  }
}

///|
const MAGENTA : String = "\u{1b}[0;35m"

///|
const NOTHING : String = "\u{1b}[m"

///|
const RED : String = "\u{1b}[1;31m"

///|
const RESET : String = "\u{1b}[0m"

///|
test "ElideMiddle.ElideAnsiEscapeCodes" {
  let input = "012345" + MAGENTA + "67890123456789"
  assert_eq(@moonja.elide_middle(input, 10), "012..." + MAGENTA + "6789")
  assert_eq(
    @moonja.elide_middle(input, 19),
    "012345" + MAGENTA + "67...23456789",
  )
  assert_eq(
    @moonja.elide_middle("Nothing " + NOTHING + " string.", 18),
    "Nothing " + NOTHING + " string.",
  )
  assert_eq(
    @moonja.elide_middle("0" + NOTHING + "1234567890123456789", 10),
    "0" + NOTHING + "12...6789",
  )
  let input = "abcd" + RED + "efg" + RESET + "hlkmnopqrstuvwxyz"
  let cases = [
    (0, "" + RED + RESET),
    (1, "." + RED + RESET),
    (2, ".." + RED + RESET),
    (3, "..." + RED + RESET),
    (4, "..." + RED + RESET + "z"),
    (5, "a..." + RED + RESET + "z"),
    (6, "a..." + RED + RESET + "yz"),
    (7, "ab..." + RED + RESET + "yz"),
    (8, "ab..." + RED + RESET + "xyz"),
    (9, "abc..." + RED + RESET + "xyz"),
    (10, "abc..." + RED + RESET + "wxyz"),
    (11, "abcd..." + RED + RESET + "wxyz"),
    (12, "abcd..." + RED + RESET + "vwxyz"),
    (15, "abcd" + RED + "ef..." + RESET + "uvwxyz"),
    (16, "abcd" + RED + "ef..." + RESET + "tuvwxyz"),
    (17, "abcd" + RED + "efg..." + RESET + "tuvwxyz"),
    (18, "abcd" + RED + "efg..." + RESET + "stuvwxyz"),
    (19, "abcd" + RED + "efg" + RESET + "h...stuvwxyz"),
  ]
  for case in cases {
    assert_eq(@moonja.elide_middle(input, case.0), case.1, msg="\{case.0}")
  }
  let input = "abcdef" + RED + "A" + RESET + "BC"
  let cases = [
    (4, "..." + RED + RESET + "C"),
    (5, "a..." + RED + RESET + "C"),
    (6, "a..." + RED + RESET + "BC"),
    (7, "ab..." + RED + RESET + "BC"),
    (8, "ab..." + RED + "A" + RESET + "BC"),
    (9, "abcdef" + RED + "A" + RESET + "BC"),
  ]
  for case in cases {
    assert_eq(@moonja.elide_middle(input, case.0), case.1, msg="\{case.0}")
  }
}

///|
test "StripAnsiEscapeCodes.EscapeAtEnd" {
  assert_eq(@moonja.strip_ansi_escape_codes("foo\u{1b}"), "foo")
  assert_eq(@moonja.strip_ansi_escape_codes("foo\u{1b}["), "foo")
}

///|
test "StripAnsiEscapeCodes.StripColors" {
  // A real clang warning.
  let input = "\u{1b}[1maffixmgr.cxx:286:15: \u{1b}[0m\u{1b}[0;1;35mwarning: \u{1b}[0m\u{1b}[1musing the result... [-Wparentheses]\u{1b}[0m"
  assert_eq(
    @moonja.strip_ansi_escape_codes(input),
    "affixmgr.cxx:286:15: warning: using the result... [-Wparentheses]",
  )
}

///|
fn quiet_status() -> @moonja.StatusPrinter {
  @moonja.StatusPrinter::new(quiet_config(), FakeTerminal::new())
}

///|
test "BuildTest.StatusFormatElapsed_e" {
  let status = quiet_status()
  @moonja.Status::build_started(status)
  // Before any edge finishes the elapsed time is zero.
  assert_eq(status.format_progress_status("[%%/e%e]", 0), "[%/e0.000]")
}

///|
test "BuildTest.StatusFormatElapsed_w" {
  let status = quiet_status()
  @moonja.Status::build_started(status)
  assert_eq(status.format_progress_status("[%%/e%w]", 0), "[%/e00:00]")
}

///|
test "BuildTest.StatusFormatETA" {
  let status = quiet_status()
  @moonja.Status::build_started(status)
  // Before any edge finishes the ETA is unknown.
  assert_eq(status.format_progress_status("[%%/E%E]", 0), "[%/E?]")
}

///|
test "BuildTest.StatusFormatTimeProgress" {
  let status = quiet_status()
  @moonja.Status::build_started(status)
  assert_eq(status.format_progress_status("[%%/p%p]", 0), "[%/p  0%]")
}

///|
test "BuildTest.StatusFormatReplacePlaceholder" {
  let status = quiet_status()
  assert_eq(
    status.format_progress_status("[%%/s%s/t%t/r%r/u%u/f%f]", 0),
    "[%/s0/t0/r0/u0/f0]",
  )
}
