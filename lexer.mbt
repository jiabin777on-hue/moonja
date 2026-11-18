///|
/// Tokens of the ninja manifest language.
#derive(Eq, Debug)
pub(all) enum Token {
  Error
  Build
  Colon
  Default
  Equals
  Ident
  Include
  Indent
  Newline
  Pipe
  Pipe2
  PipeAt
  Pool
  Rule
  Subninja
  Eof
}

///|
pub fn Token::name(self : Token) -> String {
  match self {
    Error => "lexing error"
    Build => "'build'"
    Colon => "':'"
    Default => "'default'"
    Equals => "'='"
    Ident => "identifier"
    Include => "'include'"
    Indent => "indent"
    Newline => "newline"
    Pipe2 => "'||'"
    Pipe => "'|'"
    PipeAt => "'|@'"
    Pool => "'pool'"
    Rule => "'rule'"
    Subninja => "'subninja'"
    Eof => "eof"
  }
}

///|
/// Extra advice appended to "expected X" errors.
pub fn Token::error_hint(self : Token) -> String {
  match self {
    Colon => " ($ also escapes ':')"
    _ => ""
  }
}

///|
/// Port of ninja's re2c lexer. Positions are code-unit offsets into
/// `input`; the end of the input, like an embedded NUL, reads as NUL.
pub struct Lexer {
  filename : String
  input : String
  mut ofs : Int32
  /// Start of the last token read, for error messages; -1 before any.
  mut last_token : Int32
}

///|
pub fn Lexer::new(input : String, filename~ : String = "input") -> Lexer {
  { filename, input, ofs: 0, last_token: -1, }
}

///|
fn Lexer::at(self : Lexer, i : Int32) -> UInt16 {
  if i < self.input.length() {
    self.input.unsafe_get(i)
  } else {
    0
  }
}

///|
/// `[a-zA-Z0-9_.-]`, the characters of a variable or rule name.
fn is_varname_char(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-' ||
  c == '.'
}

///|
/// `[a-zA-Z0-9_-]`: names in an unbraced `$var` expansion stop at a dot.
fn is_simple_varname_char(c : UInt16) -> Bool {
  c != '.' && is_varname_char(c)
}

///|
/// Formats an error at the last token as ninja does: `file:line: message`,
/// followed by the line and a caret when the column is between 1 and 71.
pub fn Lexer::error(self : Lexer, message : String) -> String {
  let mut line = 1
  let mut line_start = 0
  if self.last_token >= 0 {
    for i in 0..<self.last_token {
      if self.input.unsafe_get(i) == '\n' {
        line += 1
        line_start = i + 1
      }
    }
  }
  let col = if self.last_token >= 0 { self.last_token - line_start } else { 0 }
  let out = StringBuilder()
  out.write_string("\{self.filename}:\{line}: \{message}\n")
  let truncate_column = 72
  if col > 0 && col < truncate_column {
    let mut len = 0
    let mut truncated = true
    while len < truncate_column {
      let c = self.at(line_start + len)
      if c == 0 || c == '\n' {
        truncated = false
        break
      }
      len += 1
    }
    out.write_string(
      self.input.unsafe_substring(start=line_start, end=line_start + len),
    )
    if truncated {
      out.write_string("...")
    }
    out.write_string("\n")
    out.write_string(" ".repeat(col))
    out.write_string("^ near here")
  }
  out.to_string()
}

///|
fn Lexer::fail(self : Lexer, message : String) -> NinjaError {
  NinjaError::Error(self.error(message))
}

///|
pub fn Lexer::describe_last_error(self : Lexer) -> String {
  if self.last_token >= 0 && self.at(self.last_token) == '\t' {
    "tabs are not allowed, use spaces"
  } else {
    "lexing error"
  }
}

///|
pub fn Lexer::unread_token(self : Lexer) -> Unit {
  self.ofs = self.last_token
}

///|
/// Reads the next token. Comments and blank space between tokens are
/// skipped; leading spaces on a line are an `Indent`.
pub fn Lexer::read_token(self : Lexer) -> Token {
  let len = self.input.length()
  let mut p = self.ofs
  let mut start = p
  let mut token = Token::Error
  while true {
    start = p
    let mut q = p
    while self.at(q) == ' ' {
      q += 1
    }
    let c = self.at(q)
    if c == '#' {
      // [ ]*"#"[^\000\n]*"\n" is a comment, but only with its newline.
      let mut r = q + 1
      while self.at(r) != 0 && self.at(r) != '\n' {
        r += 1
      }
      if self.at(r) == '\n' {
        p = r + 1
        continue
      }
      if q > p {
        token = Indent
        p = q
      } else {
        token = Error
        p = p + 1
      }
      break
    }
    if c == '\r' && self.at(q + 1) == '\n' {
      token = Newline
      p = q + 2
      break
    }
    if c == '\n' {
      token = Newline
      p = q + 1
      break
    }
    if q > p {
      token = Indent
      p = q
      break
    }
    if is_varname_char(c) {
      while is_varname_char(self.at(q)) {
        q += 1
      }
      // A keyword only when the whole name matches (longest match).
      token = match self.input.unsafe_substring(start=p, end=q) {
        "build" => Build
        "pool" => Pool
        "rule" => Rule
        "default" => Default
        "include" => Include
        "subninja" => Subninja
        _ => Ident
      }
      p = q
      break
    }
    match c {
      '=' => {
        token = Equals
        p = p + 1
      }
      ':' => {
        token = Colon
        p = p + 1
      }
      '|' =>
        if self.at(p + 1) == '@' {
          token = PipeAt
          p = p + 2
        } else if self.at(p + 1) == '|' {
          token = Pipe2
          p = p + 2
        } else {
          token = Pipe
          p = p + 1
        }
      0 => {
        token = Eof
        p = if p < len { p + 1 } else { p }
      }
      _ => {
        token = Error
        p = p + 1
      }
    }
    break
  }
  self.last_token = start
  self.ofs = p
  if token != Newline && token != Eof {
    self.eat_whitespace()
  }
  token
}

///|
/// Reads the next token if it is `token`; otherwise leaves the input as it
/// was.
pub fn Lexer::peek_token(self : Lexer, token : Token) -> Bool {
  if self.read_token() == token {
    true
  } else {
    self.unread_token()
    false
  }
}

///|
/// Skips spaces and `$`-newline continuations.
fn Lexer::eat_whitespace(self : Lexer) -> Unit {
  let mut p = self.ofs
  while true {
    let c = self.at(p)
    if c == ' ' {
      while self.at(p) == ' ' {
        p += 1
      }
    } else if c == '$' && self.at(p + 1) == '\r' && self.at(p + 2) == '\n' {
      p += 3
    } else if c == '$' && self.at(p + 1) == '\n' {
      p += 2
    } else {
      break
    }
  }
  self.ofs = p
}

///|
/// Reads a variable or rule name; None (consuming nothing) when the input
/// does not start with one.
pub fn Lexer::read_ident(self : Lexer) -> String? {
  let start = self.ofs
  let mut p = start
  while is_varname_char(self.at(p)) {
    p += 1
  }
  self.last_token = start
  if p == start {
    return None
  }
  self.ofs = p
  self.eat_whitespace()
  Some(self.input.unsafe_substring(start~, end=p))
}

///|
/// Reads a path (`path` = true, ends at a space, `:`, `|` or newline) or a
/// variable value (ends at the newline, which it consumes).
fn Lexer::read_eval_string(
  self : Lexer,
  path : Bool,
) -> EvalString raise NinjaError {
  let eval = EvalString::new()
  let mut p = self.ofs
  let mut start = p
  while true {
    start = p
    let c = self.at(p)
    if c != '$' &&
      c != ' ' &&
      c != ':' &&
      c != '\r' &&
      c != '\n' &&
      c != '|' &&
      c != 0 {
      let mut q = p + 1
      while true {
        let d = self.at(q)
        if d == '$' ||
          d == ' ' ||
          d == ':' ||
          d == '\r' ||
          d == '\n' ||
          d == '|' ||
          d == 0 {
          break
        }
        q += 1
      }
      eval.add_text(self.input.unsafe_substring(start=p, end=q))
      p = q
      continue
    }
    if c == '\r' && self.at(p + 1) == '\n' {
      if !path {
        p += 2
      }
      break
    }
    if c == ' ' || c == ':' || c == '|' || c == '\n' {
      if path {
        break
      }
      p += 1
      if c == '\n' {
        break
      }
      eval.add_text(self.input.unsafe_substring(start~, end=p))
      continue
    }
    if c == '$' {
      let d = self.at(p + 1)
      if d == '$' {
        eval.add_text("$")
        p += 2
        continue
      }
      if d == ' ' {
        eval.add_text(" ")
        p += 2
        continue
      }
      if d == '\n' || (d == '\r' && self.at(p + 2) == '\n') {
        p += if d == '\n' { 2 } else { 3 }
        while self.at(p) == ' ' {
          p += 1
        }
        continue
      }
      if d == '{' {
        let mut q = p + 2
        while is_varname_char(self.at(q)) {
          q += 1
        }
        if q > p + 2 && self.at(q) == '}' {
          eval.add_special(self.input.unsafe_substring(start=p + 2, end=q))
          p = q + 1
          continue
        }
      } else if is_simple_varname_char(d) {
        let mut q = p + 2
        while is_simple_varname_char(self.at(q)) {
          q += 1
        }
        eval.add_special(self.input.unsafe_substring(start=p + 1, end=q))
        p = q
        continue
      } else if d == ':' {
        eval.add_text(":")
        p += 2
        continue
      }
      self.last_token = start
      raise self.fail("bad $-escape (literal $ must be written as $$)")
    }
    self.last_token = start
    if c == 0 {
      raise self.fail("unexpected EOF")
    }
    raise self.fail(self.describe_last_error())
  }
  self.last_token = start
  self.ofs = p
  if path {
    self.eat_whitespace()
  }
  eval
}

///|
/// Reads a path; an empty result means there was none.
pub fn Lexer::read_path(self : Lexer) -> EvalString raise NinjaError {
  self.read_eval_string(true)
}

///|
/// Reads the rest of the line as a variable value.
pub fn Lexer::read_var_value(self : Lexer) -> EvalString raise NinjaError {
  self.read_eval_string(false)
}
