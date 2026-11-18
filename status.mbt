///|
/// Where ninja's output goes, and what the terminal can do.
pub(open) trait Terminal {
  /// Writes to standard output.
  fn write_out(Self, String) -> Unit
  /// Writes to standard error.
  fn write_err(Self, String) -> Unit
  /// Whether stdout is a terminal that can redraw a line (ninja's
  /// "smart terminal": a TTY whose TERM is not "dumb").
  fn is_smart(Self) -> Bool
  /// Whether ANSI colors may be written (a smart terminal, or
  /// CLICOLOR_FORCE set and not "0").
  fn supports_color(Self) -> Bool
  /// The terminal's width in columns; 0 if unknown.
  fn width(Self) -> Int32
}

///|
/// The visible part of `text` minus ANSI CSI sequences (ninja's
/// `StripAnsiEscapeCodes`).
pub fn strip_ansi_escape_codes(text : String) -> String {
  let out = StringBuilder(capacity=text.length())
  let len = text.length()
  let mut i = 0
  while i < len {
    let c = text.unsafe_get(i)
    if c != '\u{1b}' {
      out.write_char(c.to_int().unsafe_to_char())
      i += 1
      continue
    }
    // Only CSI sequences are stripped.
    if i + 1 >= len {
      break
    }
    if text.unsafe_get(i + 1) != '[' {
      i += 1
      continue
    }
    i += 2
    // Skip up to and including the next letter.
    while i < len {
      let d = text.unsafe_get(i)
      if (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') {
        break
      }
      i += 1
    }
    i += 1
  }
  out.to_string()
}

///|
/// An ANSI color sequence `ESC [ digits/';' m` starting at or after `from`,
/// as (start, end), or None.
fn find_color_sequence(text : String, from : Int32) -> (Int32, Int32)? {
  let len = text.length()
  let mut at = from
  while at < len {
    let mut seq = at
    while seq < len && text.unsafe_get(seq) != '\u{1b}' {
      seq += 1
    }
    if seq >= len {
      return None
    }
    // The smallest color sequence, ESC [ 0 m, has four characters.
    if seq + 4 > len {
      return None
    }
    if text.unsafe_get(seq + 1) != '[' {
      at = seq + 1
      continue
    }
    let mut end = seq + 2
    let mut incomplete = false
    while true {
      let c = text.unsafe_get(end)
      if !((c >= '0' && c <= '9') || c == ';') {
        break
      }
      end += 1
      if end == len {
        incomplete = true
        break
      }
    }
    if incomplete {
      return None
    }
    if text.unsafe_get(end) != 'm' {
      // Not a color sequence; look again after the '['.
      at = seq + 3
      continue
    }
    return Some((seq, end + 1))
  }
  None
}

///|
/// Shortens `text` to `max_width` visible characters by replacing its
/// middle with "...", keeping ANSI color sequences intact (ninja's
/// `ElideMiddleInPlace`).
pub fn elide_middle(text : String, max_width : Int32) -> String {
  let len = text.length()
  if len <= max_width {
    return text
  }
  if !text.contains("\u{1b}") {
    let ellipsis_width = 3
    if max_width <= ellipsis_width {
      return "...".unsafe_substring(start=0, end=max_width)
    }
    let remaining = max_width - ellipsis_width
    let left = remaining / 2
    let right = remaining - left
    return text.unsafe_substring(start=0, end=left) +
      "..." +
      text.unsafe_substring(start=len - right, end=len)
  }
  // Which characters belong to color sequences.
  let invisible = Array::make(len, false)
  let mut visible_width = len
  let mut search = 0
  while find_color_sequence(text, search) is Some((start, end)) {
    for i in start..<end {
      invisible[i] = true
    }
    visible_width -= end - start
    search = end
  }
  if visible_width <= max_width {
    return text
  }
  let ellipsis_width = if max_width < 3 { max_width } else { 3 }
  let visible_left = (max_width - ellipsis_width) / 2
  let visible_right = max_width - ellipsis_width - visible_left
  let gap_start = visible_left
  let gap_end = visible_width - visible_right
  let out = StringBuilder(capacity=len)
  let mut index = 0
  let mut visible_pos = 0
  // 1. The left span, visible or not.
  while index < len && visible_pos != gap_start {
    if !invisible[index] {
      visible_pos += 1
    }
    index += 1
  }
  out.write_string(text.unsafe_substring(start=0, end=index))
  // 2. The ellipsis; its color is the left span's.
  out.write_string("...".unsafe_substring(start=0, end=ellipsis_width))
  // 3. The color sequences inside the gap, so the right span keeps its
  //    color.
  while index < len && visible_pos != gap_end {
    if invisible[index] {
      out.write_char(text.unsafe_get(index).to_int().unsafe_to_char())
    } else {
      visible_pos += 1
    }
    index += 1
  }
  // 4. The rest.
  out.write_string(text.unsafe_substring(start=index, end=len))
  out.to_string()
}

///|
#derive(Eq, Debug)
pub(all) enum LineType {
  Full
  Elide
}

///|
/// Prints status lines that overwrite each other on a smart terminal, and
/// holds output back while a console-pool command owns the terminal
/// (ninja's `LinePrinter`).
pub struct LinePrinter {
  terminal : &Terminal
  smart : Bool
  color : Bool
  mut have_blank_line : Bool
  mut console_locked : Bool
  mut line_buffer : String
  mut line_type : LineType
  output_buffer : StringBuilder
}

///|
pub fn LinePrinter::new(
  terminal : &Terminal,
  smart_terminal~ : Bool = terminal.is_smart(),
) -> LinePrinter {
  {
    terminal,
    smart: smart_terminal,
    color: terminal.supports_color(),
    have_blank_line: true,
    console_locked: false,
    line_buffer: "",
    line_type: Full,
    output_buffer: StringBuilder(),
  }
}

///|
pub fn LinePrinter::is_smart_terminal(self : LinePrinter) -> Bool {
  self.smart
}

///|
pub fn LinePrinter::supports_color(self : LinePrinter) -> Bool {
  self.color
}

///|
/// Prints `line`, overwriting the previous status line on a smart terminal.
pub fn LinePrinter::print(
  self : LinePrinter,
  line : String,
  line_type : LineType,
) -> Unit {
  if self.console_locked {
    self.line_buffer = line
    self.line_type = line_type
    return
  }
  if self.smart {
    // Print over the previous line.
    self.terminal.write_out("\r")
  }
  if self.smart && line_type is Elide {
    let width = self.terminal.width()
    let shown = if width > 0 { elide_middle(line, width) } else { line }
    // Clear to the end of the line.
    self.terminal.write_out(shown + "\u{1b}[K")
    self.have_blank_line = false
  } else {
    self.terminal.write_out(line + "\n")
  }
}

///|
fn LinePrinter::print_or_buffer(self : LinePrinter, data : String) -> Unit {
  if self.console_locked {
    self.output_buffer.write_string(data)
  } else {
    self.terminal.write_out(data)
  }
}

///|
/// Prints `text` starting on a fresh line.
pub fn LinePrinter::print_on_new_line(
  self : LinePrinter,
  text : String,
) -> Unit {
  if self.console_locked && self.line_buffer != "" {
    self.output_buffer.write_string(self.line_buffer)
    self.output_buffer.write_char('\n')
    self.line_buffer = ""
  }
  if !self.have_blank_line {
    self.print_or_buffer("\n")
  }
  if text != "" {
    self.print_or_buffer(text)
  }
  self.have_blank_line = text == "" || text.has_suffix("\n")
}

///|
/// While locked, a console-pool command writes to the terminal directly and
/// everything else is buffered.
pub fn LinePrinter::set_console_locked(
  self : LinePrinter,
  locked : Bool,
) -> Unit {
  if locked == self.console_locked {
    return
  }
  if locked {
    self.print_on_new_line("")
  }
  self.console_locked = locked
  if !locked {
    self.print_on_new_line(self.output_buffer.to_string())
    if self.line_buffer != "" {
      self.print(self.line_buffer, self.line_type)
    }
    self.output_buffer.reset()
    self.line_buffer = ""
  }
}

///|
/// `value` with `digits` decimals, like printf's `%.Nf`.
fn format_fixed(value : Double, digits : Int32) -> String {
  let negative = value < 0.0
  let mut scale = 1.0
  for _ in 0..<digits {
    scale = scale * 10.0
  }
  let scaled = (value.abs() * scale).round().to_int64()
  let factor = scale.to_int64()
  let whole = scaled / factor
  let frac = scaled % factor
  let frac_text = frac.to_string()
  let padded = "0".repeat(digits - frac_text.length()) + frac_text
  let sign = if negative && scaled != 0 { "-" } else { "" }
  if digits == 0 {
    "\{sign}\{whole}"
  } else {
    "\{sign}\{whole}.\{padded}"
  }
}

///|
/// `value` right-aligned in `width` columns, like printf's `%3i`.
fn pad_left(value : String, width : Int32) -> String {
  if value.length() >= width {
    value
  } else {
    " ".repeat(width - value.length()) + value
  }
}

///|
fn two_digits(value : Int64) -> String {
  pad_left(value.to_string(), 2).replace_all(old=" ", new="0")
}

///|
/// The edge rate over the last N finished edges (ninja's
/// `SlidingRateInfo`).
struct SlidingRate {
  mut rate : Double
  n : Int32
  times : Array[Double]
  mut last_update : Int32
}

///|
fn SlidingRate::update(
  self : SlidingRate,
  hint : Int32,
  time_millis : Int64,
) -> Unit {
  if hint == self.last_update {
    return
  }
  self.last_update = hint
  if self.times.length() == self.n {
    ignore(self.times.remove(0))
  }
  self.times.push(time_millis.to_double())
  let first = self.times[0]
  let last = self.times[self.times.length() - 1]
  if last != first {
    self.rate = self.times.length().to_double() / ((last - first) / 1000.0)
  }
}

///|
/// ninja's console status: `[finished/total] description` lines, failure
/// reports and command output (ninja's `StatusPrinter`).
pub struct StatusPrinter {
  config : BuildConfig
  printer : LinePrinter
  /// `$NINJA_STATUS`, by default "[%f/%t] ".
  format : String
  mut explanations : Explanations?
  mut started_edges : Int32
  mut finished_edges : Int32
  mut total_edges : Int32
  mut running_edges : Int32
  mut time_millis : Int64
  mut cpu_time_millis : Int64
  mut time_predicted_percentage : Double
  mut eta_predictable_edges_total : Int32
  mut eta_predictable_cpu_time_total_millis : Int64
  mut eta_predictable_edges_remaining : Int32
  mut eta_predictable_cpu_time_remaining_millis : Int64
  mut eta_unpredictable_edges_remaining : Int32
  current_rate : SlidingRate
}

///|
pub fn StatusPrinter::new(
  config : BuildConfig,
  terminal : &Terminal,
  format~ : String = "[%f/%t] ",
) -> StatusPrinter {
  // Nothing fancy unless the verbosity is normal.
  let printer = LinePrinter::new(
    terminal,
    smart_terminal=terminal.is_smart() && config.verbosity is Normal,
  )
  {
    config,
    printer,
    format,
    explanations: None,
    started_edges: 0,
    finished_edges: 0,
    total_edges: 0,
    running_edges: 0,
    time_millis: 0,
    cpu_time_millis: 0,
    time_predicted_percentage: 0.0,
    eta_predictable_edges_total: 0,
    eta_predictable_cpu_time_total_millis: 0,
    eta_predictable_edges_remaining: 0,
    eta_predictable_cpu_time_remaining_millis: 0,
    eta_unpredictable_edges_remaining: 0,
    current_rate: {
      rate: -1.0,
      n: config.parallelism,
      times: [],
      last_update: -1,
    },
  }
}

///|
pub fn StatusPrinter::set_explanations(
  self : StatusPrinter,
  explanations : Explanations?,
) -> Unit {
  self.explanations = explanations
}

///|
pub fn StatusPrinter::printer(self : StatusPrinter) -> LinePrinter {
  self.printer
}

///|
fn rate_text(rate : Double) -> String {
  if rate == -1.0 {
    "?"
  } else {
    format_fixed(rate, 1)
  }
}

///|
/// Expands a `$NINJA_STATUS` format: %s started, %t total, %r running,
/// %u unstarted, %f finished, %o overall rate, %c current rate,
/// %p percentage, %e/%w elapsed, %E/%W ETA, %P time percentage, %% '%'.
pub fn StatusPrinter::format_progress_status(
  self : StatusPrinter,
  format : String,
  time_millis : Int64,
) -> String raise NinjaError {
  ignore(time_millis)
  let out = StringBuilder()
  let len = format.length()
  let mut i = 0
  while i < len {
    let c = format.unsafe_get(i)
    if c != '%' {
      out.write_char(c.to_int().unsafe_to_char())
      i += 1
      continue
    }
    i += 1
    // A '%' at the end reads the terminating NUL, an unknown placeholder.
    let p = if i < len {
      format.unsafe_get(i).to_int().unsafe_to_char()
    } else {
      '\u{0}'
    }
    match p {
      '%' => out.write_char('%')
      's' => out.write_string(self.started_edges.to_string())
      't' => out.write_string(self.total_edges.to_string())
      'r' => out.write_string(self.running_edges.to_string())
      'u' =>
        out.write_string((self.total_edges - self.started_edges).to_string())
      'f' => out.write_string(self.finished_edges.to_string())
      'o' =>
        out.write_string(
          rate_text(
            self.finished_edges.to_double() /
            (self.time_millis.to_double() / 1000.0),
          ),
        )
      'c' => {
        self.current_rate.update(self.finished_edges, self.time_millis)
        out.write_string(rate_text(self.current_rate.rate))
      }
      'p' => {
        let percent = if self.finished_edges != 0 && self.total_edges != 0 {
          100 * self.finished_edges / self.total_edges
        } else {
          0
        }
        out.write_string(pad_left(percent.to_string(), 3) + "%")
      }
      'e' | 'w' | 'E' | 'W' => {
        let elapsed_sec = self.time_millis.to_double() / 1000.0
        let mut eta_sec = -1.0
        if self.time_predicted_percentage != 0.0 {
          let total_wall_time = self.time_millis.to_double() /
            self.time_predicted_percentage
          eta_sec = (total_wall_time - self.time_millis.to_double()) / 1000.0
        }
        let with_hours = elapsed_sec >= 3600.0 || eta_sec >= 3600.0
        let sec = if p == 'e' || p == 'w' { elapsed_sec } else { eta_sec }
        if sec < 0.0 {
          out.write_string("?")
        } else if p == 'e' || p == 'E' {
          out.write_string(format_fixed(sec, 3))
        } else {
          let t = sec.to_int64()
          if with_hours {
            out.write_string(
              "\{t / 3600}:\{two_digits(t % 3600 / 60)}:\{two_digits(t % 60)}",
            )
          } else {
            out.write_string("\{two_digits(t / 60)}:\{two_digits(t % 60)}")
          }
        }
      }
      'P' =>
        out.write_string(
          pad_left(
            (100.0 * self.time_predicted_percentage).to_int().to_string(),
            3,
          ) +
          "%",
        )
      _ => raise Fatal("unknown placeholder '%\{p}' in $NINJA_STATUS")
    }
    i += 1
  }
  out.to_string()
}

///|
fn StatusPrinter::recalculate_progress_prediction(self : StatusPrinter) -> Unit {
  self.time_predicted_percentage = 0.0
  // Use the previous times only while edges with known times remain, and
  // only if this run's average is within 10x of theirs (a ccache-warm
  // previous run says little about a cold one).
  let mut use_previous_times = self.eta_predictable_edges_remaining != 0 &&
    self.eta_predictable_cpu_time_remaining_millis != 0
  if use_previous_times &&
    self.total_edges != 0 &&
    self.finished_edges != 0 &&
    self.time_millis.to_double() >= 15.0 * 1000.0 &&
    self.finished_edges.to_double() / self.total_edges.to_double() >= 0.05 {
    let actual = self.cpu_time_millis.to_double() /
      self.finished_edges.to_double()
    let previous = self.eta_predictable_cpu_time_total_millis.to_double() /
      self.eta_predictable_edges_total.to_double()
    let ratio = @cmp.maximum(previous, actual) / @cmp.minimum(previous, actual)
    use_previous_times = ratio < 10.0
  }
  let mut known = self.finished_edges
  if use_previous_times {
    known += self.eta_predictable_edges_remaining
  }
  if known == 0 {
    return
  }
  let unknown = if use_previous_times {
    self.eta_unpredictable_edges_remaining
  } else {
    self.total_edges - self.finished_edges
  }
  let mut known_total_millis = self.cpu_time_millis
  if use_previous_times {
    known_total_millis += self.eta_predictable_cpu_time_remaining_millis
  }
  let average = known_total_millis.to_double() / known.to_double()
  let mut remaining = average * unknown.to_double()
  if use_previous_times {
    remaining += self.eta_predictable_cpu_time_remaining_millis.to_double()
  }
  let total = self.cpu_time_millis.to_double() + remaining
  if total == 0.0 {
    return
  }
  self.time_predicted_percentage = self.cpu_time_millis.to_double() / total
}

///|
fn binding_or_empty(edge : Edge, key : String) -> String {
  edge.get_binding(key) catch {
    _ => ""
  }
}

///|
fn StatusPrinter::print_status(
  self : StatusPrinter,
  edge : Edge,
  time_millis : Int64,
) -> Unit {
  if self.explanations is Some(explanations) {
    let lines = []
    for out in edge.outputs {
      for line in explanations.lookup(out) {
        lines.push(line)
      }
    }
    if !lines.is_empty() {
      // Do not append the first explanation to the status line.
      self.printer.print_on_new_line("")
      for line in lines {
        self.printer.terminal.write_err("ninja explain: \{line}\n")
      }
    }
  }
  if self.config.verbosity is (Quiet | NoStatusUpdate) {
    return
  }
  self.recalculate_progress_prediction()
  let full = self.config.verbosity is Verbose
  let mut text = binding_or_empty(edge, "description")
  if text == "" || full {
    text = binding_or_empty(edge, "command")
  }
  let prefix = self.format_progress_status(self.format, time_millis) catch {
    error => {
      self.printer.terminal.write_err("ninja: fatal: \{error.message()}\n")
      ""
    }
  }
  self.printer.print(prefix + text, if full { Full } else { Elide })
}

///|
pub impl Status for StatusPrinter with fn edge_added_to_plan(self, edge) {
  self.total_edges += 1
  // Do we know how long it took last time?
  if edge.prev_elapsed_time_millis != -1 {
    self.eta_predictable_edges_total += 1
    self.eta_predictable_edges_remaining += 1
    self.eta_predictable_cpu_time_total_millis += edge.prev_elapsed_time_millis
    self.eta_predictable_cpu_time_remaining_millis += edge.prev_elapsed_time_millis
  } else {
    self.eta_unpredictable_edges_remaining += 1
  }
}

///|
pub impl Status for StatusPrinter with fn edge_removed_from_plan(self, edge) {
  self.total_edges -= 1
  if edge.prev_elapsed_time_millis != -1 {
    self.eta_predictable_edges_total -= 1
    self.eta_predictable_edges_remaining -= 1
    self.eta_predictable_cpu_time_total_millis -= edge.prev_elapsed_time_millis
    self.eta_predictable_cpu_time_remaining_millis -= edge.prev_elapsed_time_millis
  } else {
    self.eta_unpredictable_edges_remaining -= 1
  }
}

///|
pub impl Status for StatusPrinter with fn build_edge_started(self, edge, start) {
  self.started_edges += 1
  self.running_edges += 1
  self.time_millis = start
  if edge.use_console() || self.printer.is_smart_terminal() {
    self.print_status(edge, start)
  }
  if edge.use_console() {
    self.printer.set_console_locked(true)
  }
}

///|
pub impl Status for StatusPrinter with fn build_edge_finished(
  self,
  edge,
  start,
  end,
  exit_code,
  output,
) {
  self.time_millis = end
  self.finished_edges += 1
  self.cpu_time_millis += end - start
  if edge.prev_elapsed_time_millis != -1 {
    self.eta_predictable_edges_remaining -= 1
    self.eta_predictable_cpu_time_remaining_millis -= edge.prev_elapsed_time_millis
  } else {
    self.eta_unpredictable_edges_remaining -= 1
  }
  if edge.use_console() {
    self.printer.set_console_locked(false)
  }
  if self.config.verbosity is Quiet {
    return
  }
  if !edge.use_console() {
    self.print_status(edge, end)
  }
  self.running_edges -= 1
  // Show the failing command before its output.
  if !(exit_code is Success) {
    let outputs = StringBuilder()
    for out in edge.outputs {
      outputs.write_string(out.path + " ")
    }
    let failed = "FAILED: [code=\{exit_code.code()}] "
    if self.printer.supports_color() {
      self.printer.print_on_new_line(
        "\u{1b}[31m" + failed + "\u{1b}[0m" + outputs.to_string() + "\n",
      )
    } else {
      self.printer.print_on_new_line(failed + outputs.to_string() + "\n")
    }
    let command = edge.evaluate_command() catch { _ => "" }
    self.printer.print_on_new_line(command + "\n")
  }
  if output != "" {
    // Commands get a pipe, so compilers may be told to always print color;
    // strip it again unless the terminal shows color.
    if self.printer.supports_color() || !output.contains("\u{1b}") {
      self.printer.print_on_new_line(output)
    } else {
      self.printer.print_on_new_line(strip_ansi_escape_codes(output))
    }
  }
}

///|
pub impl Status for StatusPrinter with fn build_started(self) {
  self.started_edges = 0
  self.finished_edges = 0
  self.running_edges = 0
}

///|
pub impl Status for StatusPrinter with fn build_finished(self) {
  self.printer.set_console_locked(false)
  self.printer.print_on_new_line("")
}

///|
pub impl Status for StatusPrinter with fn info(self, message) {
  self.printer.terminal.write_out("ninja: \{message}\n")
}

///|
pub impl Status for StatusPrinter with fn warning(self, message) {
  self.printer.terminal.write_err("ninja: warning: \{message}\n")
}

///|
pub impl Status for StatusPrinter with fn error(self, message) {
  self.printer.terminal.write_err("ninja: error: \{message}\n")
}
