///|
/// Errors raised while loading or evaluating a build manifest.
///
/// `Error` carries a message that ninja prints as `ninja: error: ...`;
/// `Fatal` corresponds to ninja's `Fatal()`, printed as `ninja: fatal: ...`.
#derive(Debug)
pub(all) suberror NinjaError {
  Error(String)
  Fatal(String)
}

///|
pub fn NinjaError::message(self : NinjaError) -> String {
  match self {
    Error(message) | Fatal(message) => message
  }
}

///|
/// The ninja release whose behavior moonja reproduces. It is reported by
/// `--version` and checked against `ninja_required_version`.
pub let ninja_version : String = "1.13.2"

///|
/// The host conventions that ninja selects at compile time with `_WIN32`.
/// moonja takes them as a value, so both variants run on every host and in
/// every test.
#derive(Eq, Debug)
pub(all) enum Platform {
  Posix
  Windows
}

///|
fn Platform::is_separator(self : Platform, c : UInt16) -> Bool {
  c == '/' || (self is Windows && c == '\\')
}

///|
fn is_canonical(path : String, platform : Platform) -> Bool {
  // True when canonicalize_path would return the path unchanged with no
  // slash bits: no empty, `.` or `..` component, no trailing separator, and
  // on Windows no backslash. Most manifest paths are like this, and
  // skipping the copy is a large part of parsing time on the JS backend.
  let len = path.length()
  let windows = platform is Windows
  // Start of the current component; a single root separator is allowed.
  let mut start = if path.unsafe_get(0) == '/' { 1 } else { 0 }
  if windows && path.unsafe_get(0) == '\\' {
    return false
  }
  if start == len {
    // "/" itself.
    return true
  }
  for i in start..<len {
    let c = path.unsafe_get(i)
    if c == '/' || (windows && c == '\\') {
      if c == '\\' {
        return false
      }
      let n = i - start
      if n == 0 ||
        (n == 1 && path.unsafe_get(start) == '.') ||
        (
          n == 2 &&
          path.unsafe_get(start) == '.' &&
          path.unsafe_get(start + 1) == '.'
        ) {
        return false
      }
      start = i + 1
    }
  }
  let n = len - start
  !(n == 0 ||
  (n == 1 && path.unsafe_get(start) == '.') ||
  (n == 2 && path.unsafe_get(start) == '.' && path.unsafe_get(start + 1) == '.'))
}

///|
/// Port of ninja's `CanonicalizePath`: removes `.` components, empty
/// components and `..` where possible, without touching the file system.
/// On Windows, backslashes become `/` and the returned bits record which
/// separators were backslashes (bit i for the i-th separator), so the path
/// can be decanonicalized for command lines.
pub fn canonicalize_path(
  path : String,
  platform~ : Platform = Posix,
) -> (String, UInt64) {
  let len = path.length()
  if len == 0 {
    return ("", 0)
  }
  if is_canonical(path, platform) {
    return (path, 0)
  }
  canonicalize_path_copy(path, platform)
}

///|
/// canonicalize_path without the shortcut for paths already in canonical form.
fn canonicalize_path_copy(
  path : String,
  platform : Platform,
) -> (String, UInt64) {
  let len = path.length()
  let buf : Array[UInt16] = Array::makei(len, fn(i) { path.unsafe_get(i) })
  let sep = fn(c : UInt16) { platform.is_separator(c) }
  let end = len
  let mut src = 0
  let mut dst = 0
  let mut dst_start = 0
  if sep(buf[0]) {
    // Keep the root separator (two for a Windows network path).
    if platform is Windows && 2 <= end && sep(buf[1]) {
      src = 2
      dst = 2
    } else {
      src = 1
      dst = 1
    }
    dst_start = dst
  } else {
    // Leading ../ components are kept as they are.
    while src + 3 <= end &&
          buf[src] == '.' &&
          buf[src + 1] == '.' &&
          sep(buf[src + 2]) {
      src += 3
      dst += 3
    }
  }
  let mut component_count = 0
  let dst0 = dst
  // Every component except the last one ends with a separator.
  while src < end {
    let mut next_sep = src
    while next_sep < end && !sep(buf[next_sep]) {
      next_sep += 1
    }
    if next_sep == end {
      break
    }
    let current = src
    let src_next = next_sep + 1
    src = src_next
    let component_len = next_sep - current
    if component_len <= 2 {
      if component_len == 0 {
        continue
      }
      if buf[current] == '.' {
        if component_len == 1 {
          continue
        } else if buf[current + 1] == '.' {
          if component_count > 0 {
            component_count -= 1
            dst -= 1
            while dst > dst0 && !sep(buf[dst - 1]) {
              dst -= 1
            }
          } else {
            buf[dst] = '.'
            buf[dst + 1] = '.'
            buf[dst + 2] = buf[current + 2]
            dst += 3
          }
          continue
        }
      }
    }
    component_count += 1
    for i in current..<src_next {
      buf[dst] = buf[i]
      dst += 1
    }
  }
  // The last component has no trailing separator.
  let component_len = end - src
  if component_len == 0 {
    ()
  } else if buf[src] == '.' && component_len == 1 {
    ()
  } else if buf[src] == '.' && component_len == 2 && buf[src + 1] == '.' {
    if component_count > 0 {
      dst -= 1
      while dst > dst0 && !sep(buf[dst - 1]) {
        dst -= 1
      }
    } else {
      buf[dst] = '.'
      buf[dst + 1] = '.'
      dst += 2
    }
  } else {
    for i in src..<end {
      buf[dst] = buf[i]
      dst += 1
    }
  }
  if dst > dst_start && sep(buf[dst - 1]) {
    dst -= 1
  }
  if dst == 0 {
    buf[0] = '.'
    dst = 1
  }
  let mut bits : UInt64 = 0
  if platform is Windows {
    let mut mask : UInt64 = 1
    for i in 0..<dst {
      if buf[i] == '\\' {
        bits = bits | mask
        buf[i] = '/'
        mask = mask << 1
      } else if buf[i] == '/' {
        mask = mask << 1
      }
    }
  }
  let out = StringBuilder(capacity=dst)
  for i in 0..<dst {
    out.write_char(Int32::unsafe_to_char(buf[i].to_int()))
  }
  (out.to_string(), bits)
}

///|
/// The path as written in the manifest: on Windows, the separators recorded
/// in `slash_bits` become backslashes again.
pub fn decanonicalize_path(
  path : String,
  slash_bits : UInt64,
  platform~ : Platform = Posix,
) -> String {
  guard platform is Windows && slash_bits != 0 else { return path }
  let out = StringBuilder(capacity=path.length())
  let mut mask : UInt64 = 1
  for c in path {
    if c == '/' {
      out.write_char(if (slash_bits & mask) != 0 { '\\' } else { '/' })
      mask = mask << 1
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn is_shell_safe(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '+' ||
  c == '-' ||
  c == '.' ||
  c == '/'
}

///|
/// Port of `GetShellEscapedString`: single-quotes a path for `/bin/sh` when
/// it contains anything outside `[A-Za-z0-9_+\-./]`.
pub fn shell_escape(input : String, out : StringBuilder) -> Unit {
  if input.iter().all(is_shell_safe) {
    out.write_string(input)
    return
  }
  out.write_char('\'')
  for c in input {
    if c == '\'' {
      out.write_string("'\\''")
    } else {
      out.write_char(c)
    }
  }
  out.write_char('\'')
}

///|
/// Port of `GetWin32EscapedString`: quotes a path for `CommandLineToArgvW`
/// when it contains a space or a double quote, doubling the backslashes
/// that precede a quote or the closing quote.
pub fn win32_escape(input : String, out : StringBuilder) -> Unit {
  if !input.iter().any(fn(c) { c == ' ' || c == '"' }) {
    out.write_string(input)
    return
  }
  out.write_char('"')
  let mut backslashes = 0
  for c in input {
    match c {
      '\\' => {
        backslashes += 1
        out.write_char(c)
      }
      '"' => {
        for _ in 0..<(backslashes + 1) {
          out.write_char('\\')
        }
        out.write_char(c)
        backslashes = 0
      }
      _ => {
        backslashes = 0
        out.write_char(c)
      }
    }
  }
  for _ in 0..<backslashes {
    out.write_char('\\')
  }
  out.write_char('"')
}

///|
/// C `atoi`: optional leading whitespace and sign, then decimal digits up to
/// the first other character; 0 when there are none.
pub fn atoi(text : String) -> Int32 {
  let mut i = 0
  let len = text.length()
  while i < len &&
        [' ', '\t', '\n', '\r', '\u{0B}', '\u{0C}'].contains(
          text.unsafe_get(i).to_int().unsafe_to_char(),
        ) {
    i += 1
  }
  let mut negative = false
  if i < len && (text.unsafe_get(i) == '-' || text.unsafe_get(i) == '+') {
    negative = text.unsafe_get(i) == '-'
    i += 1
  }
  let mut value = 0
  while i < len && text.unsafe_get(i) >= '0' && text.unsafe_get(i) <= '9' {
    value = value * 10 + (text.unsafe_get(i).to_int() - '0'.to_int())
    i += 1
  }
  if negative {
    -value
  } else {
    value
  }
}

///|
/// Orders strings by code unit, like `std::map<std::string, ...>` does for
/// ASCII keys (`String::compare` puts shorter strings first).
pub fn compare_lexical(a : String, b : String) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.unsafe_get(i)
    let y = b.unsafe_get(i)
    if x != y {
      return x.compare(y)
    }
  }
  a.length().compare(b.length())
}
