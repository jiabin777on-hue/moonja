///|
/// The result of filtering MSVC `/showIncludes` output.
pub struct ClOutput {
  /// Included files, sorted and without system headers.
  includes : Array[String]
  /// The output without the include notes and the echoed file name.
  filtered : String
}

///|
pub fn ClOutput::includes(self : ClOutput) -> Array[String] {
  self.includes
}

///|
pub fn ClOutput::filtered(self : ClOutput) -> String {
  self.filtered
}

///|
/// The included path if `line` is an include note: `deps_prefix` (by
/// default English "Note: including file: "), then spaces, then the path.
pub fn filter_show_includes(line : String, deps_prefix : String) -> String {
  let prefix = if deps_prefix == "" {
    "Note: including file: "
  } else {
    deps_prefix
  }
  if line.length() > prefix.length() && line.has_prefix(prefix) {
    let mut at = prefix.length()
    while at < line.length() && line.unsafe_get(at) == ' ' {
      at += 1
    }
    return line.unsafe_substring(start=at, end=line.length())
  }
  ""
}

///|
/// A guess: headers under Program Files or Visual Studio are system ones.
pub fn is_system_include(path : String) -> Bool {
  let lower = path.to_lower()
  lower.contains("program files") || lower.contains("microsoft visual studio")
}

///|
/// cl.exe echoes the name of the file it compiles.
pub fn filter_input_filename(line : String) -> Bool {
  let lower = line.to_lower()
  lower.has_suffix(".c") ||
  lower.has_suffix(".cc") ||
  lower.has_suffix(".cxx") ||
  lower.has_suffix(".cpp") ||
  lower.has_suffix(".c++")
}

///|
/// Port of ninja's `CLParser::Parse`. With a `normalizer` (ninja on
/// Windows) include paths are made relative to its directory; without one
/// they are only canonicalized, as on other systems.
pub fn parse_cl_output(
  output : String,
  deps_prefix : String,
  normalizer? : IncludesNormalize,
) -> ClOutput raise NinjaError {
  let includes : Map[String, Unit] = Map([])
  let filtered = StringBuilder()
  let mut seen_show_includes = false
  let mut start = 0
  let len = output.length()
  while start < len {
    let mut end = start
    while end < len &&
          output.unsafe_get(end) != '\r' &&
          output.unsafe_get(end) != '\n' {
      end += 1
    }
    let line = output.unsafe_substring(start~, end~)
    let included = filter_show_includes(line, deps_prefix)
    if included != "" {
      seen_show_includes = true
      let normalized = match normalizer {
        Some(n) => n.normalize(included)
        None => canonicalize_path(included).0
      }
      if !is_system_include(normalized) {
        includes[normalized] = ()
      }
    } else if !seen_show_includes && filter_input_filename(line) {
      // Drop the echoed file name.
      ()
    } else {
      filtered.write_string(line)
      filtered.write_char('\n')
    }
    if end < len && output.unsafe_get(end) == '\r' {
      end += 1
    }
    if end < len && output.unsafe_get(end) == '\n' {
      end += 1
    }
    start = end
  }
  let sorted = includes.keys().collect()
  sorted.sort_by(compare_lexical)
  { includes: sorted, filtered: filtered.to_string(), }
}
