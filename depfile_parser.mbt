///|
/// The targets and dependencies of a Makefile-style depfile, as written by
/// `gcc -M`/`clang -M`. Duplicates are removed; order is preserved.
pub struct Depfile {
  outs : Array[String]
  ins : Array[String]
}

///|
pub fn Depfile::outs(self : Depfile) -> Array[String] {
  self.outs
}

///|
pub fn Depfile::ins(self : Depfile) -> Array[String] {
  self.ins
}

///|
/// Plain text in a depfile name:
/// `[a-zA-Z0-9+?"'&,/_:.~()}{%=@[\]!\x80-\xFF-]`.
fn is_depfile_text(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c >= 0x80 ||
  (match c.to_int().unsafe_to_char() {
    '+'
    | '?'
    | '"'
    | '\''
    | '&'
    | ','
    | '/'
    | '_'
    | ':'
    | '.'
    | '~'
    | '('
    | ')' => true
    '}' | '{' | '%' | '=' | '@' | '[' | ']' | '!' | '-' => true
    _ => false
  })
}

///|
/// Port of ninja's re2c depfile parser. Following GCC and Clang, a
/// backslash escapes a space or `#`: 2N+1 backslashes and a space are N
/// backslashes and a space; 2N backslashes and a space are 2N backslashes
/// that end the name. `\:` is a colon unless whitespace follows it, and
/// `$$` is a dollar sign. Other backslashes are kept.
pub fn parse_depfile(content : String) -> Depfile raise NinjaError {
  let end = content.length()
  let at = fn(i : Int32) -> UInt16 {
    if i < end {
      content.unsafe_get(i)
    } else {
      0
    }
  }
  let outs : Array[String] = []
  let ins : Array[String] = []
  let mut have_target = false
  let mut parsing_targets = true
  let mut poisoned_input = false
  let mut is_empty = true
  let mut pos = 0
  while pos < end {
    let mut have_newline = false
    let out = StringBuilder()
    let backslashes = fn(n : Int32) {
      for _ in 0..<n {
        out.write_char('\\')
      }
    }
    let copy = fn(from : Int32, to : Int32) {
      out.write_string(content.unsafe_substring(start=from, end=to))
    }
    // Each rule below is the longest match at `start`; on a tie, the rule
    // listed first in ninja's grammar wins.
    while true {
      let start = pos
      let c = at(start)
      if c == '\\' {
        let mut k = 0
        while at(start + k) == '\\' {
          k += 1
        }
        let next = at(start + k)
        if next == ' ' {
          pos = start + k + 1
          if k % 2 == 1 {
            // 2N+1 backslashes and a space: N backslashes and a space.
            backslashes(k / 2)
            out.write_char(' ')
            continue
          }
          // 2N backslashes and a space end the name.
          backslashes(k)
          break
        }
        if next == '#' {
          backslashes(k - 1)
          out.write_char('#')
          pos = start + k + 1
          continue
        }
        if next == ':' {
          let after = at(start + k + 1)
          if after == 0 ||
            after == ' ' ||
            after == '\r' ||
            after == '\n' ||
            after == '\t' {
            // A colon followed by whitespace ends a target; the
            // backslashes are kept and the whitespace is consumed.
            copy(start, start + k + 1)
            pos = start + k + 2
            if after == '\n' {
              have_newline = true
            }
            break
          }
          backslashes(k - 1)
          out.write_char(':')
          pos = start + k + 1
          continue
        }
        if next != 0 && next != '\r' && next != '\n' {
          // Backslashes before any other character are text.
          copy(start, start + k + 1)
          pos = start + k + 1
          continue
        }
        if k >= 2 {
          // The last backslash is the "any character" of `\\+[^\0\r\n]`.
          copy(start, start + k)
          pos = start + k
          continue
        }
        // A single backslash before a newline continues the line; before
        // NUL or a lone CR it is swallowed. Either way the name ends.
        if next == '\n' {
          pos = start + 2
        } else if next == '\r' && at(start + 2) == '\n' {
          pos = start + 3
        } else {
          pos = start + 1
        }
        break
      }
      if c == '$' && at(start + 1) == '$' {
        out.write_char('$')
        pos = start + 2
        continue
      }
      if is_depfile_text(c) {
        let mut q = start + 1
        while is_depfile_text(at(q)) {
          q += 1
        }
        copy(start, q)
        pos = q
        continue
      }
      if c == '\n' {
        have_newline = true
        pos = start + 1
        break
      }
      if c == '\r' && at(start + 1) == '\n' {
        have_newline = true
        pos = start + 2
        break
      }
      // NUL, whitespace or anything else ends the name and is dropped.
      pos = start + 1
      break
    }
    let mut filename = out.to_string()
    let is_dependency = !parsing_targets
    if filename.has_suffix(":") {
      filename = filename.unsafe_substring(start=0, end=filename.length() - 1)
      parsing_targets = false
      have_target = true
    }
    if filename != "" {
      is_empty = false
      if !ins.contains(filename) {
        if is_dependency {
          if poisoned_input {
            raise Error("inputs may not also have inputs")
          }
          ins.push(filename)
        } else if !outs.contains(filename) {
          outs.push(filename)
        }
      } else if !is_dependency {
        // An input appeared as a target: it may not get inputs of its own.
        poisoned_input = true
      }
    }
    if have_newline {
      // A newline ends the rule; the next name is a target again.
      parsing_targets = true
      poisoned_input = false
    }
  }
  if !have_target && !is_empty {
    raise Error("expected ':' in depfile")
  }
  { outs, ins, }
}
