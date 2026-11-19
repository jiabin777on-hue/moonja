// Ported from ninja v1.13.2 src/includes_normalize-win32.cc (Apache-2.0,
// see NOTICE). ninja asks GetFullPathNameA for absolute paths; here the
// working directory is given, so the Windows behavior runs and is tested
// anywhere.

///|
/// Windows' MAX_PATH, the limit of the ANSI file APIs ninja uses.
let max_path : Int32 = 260

///|
fn is_win_separator(c : UInt16) -> Bool {
  c == '/' || c == '\\'
}

///|
fn is_latin_alpha(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn to_lower_ascii(c : UInt16) -> UInt16 {
  if c >= 'A' && c <= 'Z' {
    c + 32
  } else {
    c
  }
}

///|
fn equals_case_insensitive_ascii(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if to_lower_ascii(a.unsafe_get(i)) != to_lower_ascii(b.unsafe_get(i)) {
      return false
    }
  }
  true
}

///|
/// Whether `s` looks like GetFullPathName's output: `X:\` and no `.` or
/// `..` components (either separator).
fn is_full_path_name(s : String) -> Bool {
  let len = s.length()
  if len < 3 ||
    !is_latin_alpha(s.unsafe_get(0)) ||
    s.unsafe_get(1) != ':' ||
    !is_win_separator(s.unsafe_get(2)) {
    return false
  }
  for i in 2..<len {
    if !is_win_separator(s.unsafe_get(i)) {
      continue
    }
    if i + 1 < len &&
      s.unsafe_get(i + 1) == '.' &&
      (i + 2 >= len || is_win_separator(s.unsafe_get(i + 2))) {
      return false
    }
    if i + 2 < len &&
      s.unsafe_get(i + 1) == '.' &&
      s.unsafe_get(i + 2) == '.' &&
      (i + 3 >= len || is_win_separator(s.unsafe_get(i + 3))) {
      return false
    }
  }
  true
}

///|
/// GetFullPathNameA: `path` made absolute against `cwd` with `.` and `..`
/// resolved and backslashes as separators.
pub fn full_path_name(path : String, cwd : String) -> String raise NinjaError {
  if path.length() >= max_path {
    // The ANSI API fails on inputs this long.
    raise Error(
      "GetFullPathNameA(\{path}): The filename or extension is too long.\r\n",
    )
  }
  let p = path.replace_all(old="/", new="\\")
  let dir = cwd.replace_all(old="/", new="\\")
  let has_drive = fn(s : String) {
    s.length() >= 2 && is_latin_alpha(s.unsafe_get(0)) && s.unsafe_get(1) == ':'
  }
  // Split into a root ("C:") and the components to resolve.
  let (root, rest) = if has_drive(p) &&
    p.length() >= 3 &&
    p.unsafe_get(2) == '\\' {
    (
      p.unsafe_substring(start=0, end=2),
      p.unsafe_substring(start=3, end=p.length()),
    )
  } else if p.has_prefix("\\") {
    // Rooted on the current drive.
    (
      dir.unsafe_substring(start=0, end=2),
      p.unsafe_substring(start=1, end=p.length()),
    )
  } else if has_drive(p) {
    // Drive-relative: against the working directory if it is that drive.
    let rel = p.unsafe_substring(start=2, end=p.length())
    if has_drive(dir) &&
      to_lower_ascii(dir.unsafe_get(0)) == to_lower_ascii(p.unsafe_get(0)) {
      (
        dir.unsafe_substring(start=0, end=2),
        dir.unsafe_substring(start=3, end=dir.length()) + "\\" + rel,
      )
    } else {
      (p.unsafe_substring(start=0, end=2), rel)
    }
  } else {
    (
      dir.unsafe_substring(start=0, end=2),
      dir.unsafe_substring(start=3, end=dir.length()) + "\\" + p,
    )
  }
  let parts : Array[String] = []
  for part in rest.split("\\") {
    let part = part.to_owned()
    match part {
      "" | "." => ()
      ".." => ignore(parts.pop())
      _ => parts.push(part)
    }
  }
  let trailing = p.has_suffix("\\") && !parts.is_empty()
  let result = root +
    "\\" +
    parts.join("\\") +
    (if trailing { "\\" } else { "" })
  if result.length() + 1 > max_path {
    raise Error("path too long")
  }
  result
}

///|
/// Makes the include paths of `/showIncludes` relative to a directory, as
/// ninja does on Windows for `deps = msvc` (ninja's `IncludesNormalize`).
pub struct IncludesNormalize {
  cwd : String
  relative_to : String
  split_relative_to : Array[String]
}

///|
/// `relative_to` is resolved against `cwd`, the working directory.
pub fn IncludesNormalize::new(
  relative_to : String,
  cwd : String,
) -> IncludesNormalize raise NinjaError {
  let absolute = IncludesNormalize::abs_path(relative_to, cwd) catch {
    error => raise Fatal("Initializing IncludesNormalize(): \{error.message()}")
  }
  {
    cwd,
    relative_to: absolute,
    split_relative_to: absolute.split("/").map(fn(s) { s.to_owned() }).collect(),
  }
}

///|
/// `s` made absolute, with forward slashes.
pub fn IncludesNormalize::abs_path(
  s : String,
  cwd : String,
) -> String raise NinjaError {
  if is_full_path_name(s) {
    return s.replace_all(old="\\", new="/")
  }
  full_path_name(s, cwd).replace_all(old="\\", new="/")
}

///|
/// Whether two absolute paths are on the same drive.
fn same_drive(a : String, b : String) -> Bool {
  let fast = a.length() >= 3 &&
    b.length() >= 3 &&
    is_latin_alpha(a.unsafe_get(0)) &&
    is_latin_alpha(b.unsafe_get(0)) &&
    to_lower_ascii(a.unsafe_get(0)) == to_lower_ascii(b.unsafe_get(0)) &&
    a.unsafe_get(1) == ':' &&
    b.unsafe_get(1) == ':' &&
    is_win_separator(a.unsafe_get(2)) &&
    is_win_separator(b.unsafe_get(2))
  if fast {
    return true
  }
  // Both are absolute already; compare their drives.
  a.length() >= 2 &&
  b.length() >= 2 &&
  a.unsafe_get(1) == ':' &&
  b.unsafe_get(1) == ':' &&
  to_lower_ascii(a.unsafe_get(0)) == to_lower_ascii(b.unsafe_get(0))
}

///|
fn IncludesNormalize::relativize(
  self : IncludesNormalize,
  path : String,
  start_list : Array[String],
) -> String raise NinjaError {
  let abs = IncludesNormalize::abs_path(path, self.cwd)
  let path_list = abs.split("/").map(fn(s) { s.to_owned() }).collect()
  let mut i = 0
  while i < start_list.length() &&
        i < path_list.length() &&
        equals_case_insensitive_ascii(start_list[i], path_list[i]) {
    i += 1
  }
  let rel = []
  for _ in i..<start_list.length() {
    rel.push("..")
  }
  for j in i..<path_list.length() {
    rel.push(path_list[j])
  }
  if rel.is_empty() {
    "."
  } else {
    rel.join("/")
  }
}

///|
/// `input` canonicalized and made relative to the directory, unless it is
/// on another drive.
pub fn IncludesNormalize::normalize(
  self : IncludesNormalize,
  input : String,
) -> String raise NinjaError {
  if input.length() > max_path {
    raise Error("path too long")
  }
  let (partially_fixed, _) = canonicalize_path(input, platform=Windows)
  let abs_input = IncludesNormalize::abs_path(partially_fixed, self.cwd)
  if !same_drive(abs_input, self.relative_to) {
    return partially_fixed
  }
  self.relativize(abs_input, self.split_relative_to)
}
