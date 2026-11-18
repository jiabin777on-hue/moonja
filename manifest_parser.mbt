///|
/// Reads `include`d and `subninja` files. Errors carry the system message,
/// e.g. "No such file or directory".
pub(open) trait FileReader {
  fn read_file(Self, String) -> String raise NinjaError
}

///|
/// What to do with `build a: phony a` (written by CMake 2.8.12.x/3.0.x).
#derive(Eq, Debug)
pub(all) enum PhonyCycleAction {
  /// Drop the self-reference and warn (`-w phonycycle=warn`, the default).
  Warn
  /// Keep it, so the build reports a dependency cycle.
  Error
}

///|
pub(all) struct ManifestParserOptions {
  phony_cycle_action : PhonyCycleAction
}

///|
pub fn ManifestParserOptions::default() -> ManifestParserOptions {
  { phony_cycle_action: Warn, }
}

///|
/// Parses `.ninja` files into a `State`.
pub struct ManifestParser {
  state : State
  read : ((String) -> String raise NinjaError)?
  options : ManifestParserOptions
  env : BindingEnv
  mut quiet : Bool
  mut lexer : Lexer
  /// Warnings in the order ninja would print them (without "ninja: warning: ").
  warnings : Array[String]
}

///|
pub fn[R : FileReader] ManifestParser::new(
  state : State,
  reader? : R,
  options~ : ManifestParserOptions = ManifestParserOptions::default(),
) -> ManifestParser {
  let read = match reader {
    Some(reader) =>
      Some(fn(path : String) raise NinjaError { reader.read_file(path) })
    None => None
  }
  {
    state,
    read,
    options,
    env: state.bindings,
    quiet: false,
    lexer: Lexer::new(""),
    warnings: [],
  }
}

///|
/// A parser that cannot read other files.
pub fn ManifestParser::without_files(
  state : State,
  options~ : ManifestParserOptions = ManifestParserOptions::default(),
) -> ManifestParser {
  {
    state,
    read: None,
    options,
    env: state.bindings,
    quiet: false,
    lexer: Lexer::new(""),
    warnings: [],
  }
}

///|
pub fn ManifestParser::warnings(self : ManifestParser) -> Array[String] {
  self.warnings
}

///|
fn ManifestParser::subparser(
  self : ManifestParser,
  env : BindingEnv,
) -> ManifestParser {
  {
    state: self.state,
    read: self.read,
    options: self.options,
    env,
    quiet: self.quiet,
    lexer: Lexer::new(""),
    warnings: self.warnings,
  }
}

///|
/// Loads and parses `filename`. When `parent` is given (an `include` or
/// `subninja`), a read failure is reported at the parent's position.
pub fn ManifestParser::load(
  self : ManifestParser,
  filename : String,
  parent? : Lexer,
) -> Unit raise NinjaError {
  let contents = match self.read {
    Some(read) =>
      read(filename) catch {
        error => {
          let message = "loading '\{filename}': \{error.message()}"
          match parent {
            Some(lexer) => raise Error(lexer.error(message))
            None => raise Error(message)
          }
        }
      }
    None => {
      let message = "loading '\{filename}': No such file or directory"
      match parent {
        Some(lexer) => raise Error(lexer.error(message))
        None => raise Error(message)
      }
    }
  }
  self.parse(filename, contents)
}

///|
/// Parses `input` as a file named "input", without warnings (ninja's
/// `ParseTest`).
pub fn ManifestParser::parse_test(
  self : ManifestParser,
  input : String,
) -> Unit raise NinjaError {
  self.quiet = true
  self.parse("input", input)
}

///|
pub fn ManifestParser::parse(
  self : ManifestParser,
  filename : String,
  input : String,
) -> Unit raise NinjaError {
  self.lexer = Lexer::new(input, filename~)
  while true {
    let token = self.lexer.read_token()
    match token {
      Pool => self.parse_pool()
      Build => self.parse_edge()
      Rule => self.parse_rule()
      Default => self.parse_default()
      Ident => {
        self.lexer.unread_token()
        let (name, let_value) = self.parse_let()
        let value = let_value.evaluate(self.env)
        // Check the version at once, before any syntax it might not know.
        if name == "ninja_required_version" {
          self.check_ninja_version(value)
        }
        self.env.add_binding(name, value)
      }
      Include => self.parse_file_include(false)
      Subninja => self.parse_file_include(true)
      Error => raise self.lexer.fail(self.lexer.describe_last_error())
      Eof => return
      Newline => ()
      _ => raise self.lexer.fail("unexpected \{token.name()}")
    }
  }
}

///|
fn parse_version(version : String) -> (Int32, Int32) {
  match version.find(".") {
    None => (atoi(version), 0)
    Some(end) => {
      let major = atoi(version.unsafe_substring(start=0, end~))
      let rest = version.unsafe_substring(start=end + 1, end=version.length())
      let minor = match rest.find(".") {
        Some(dot) => atoi(rest.unsafe_substring(start=0, end=dot))
        None => atoi(rest)
      }
      (major, minor)
    }
  }
}

///|
fn ManifestParser::check_ninja_version(
  self : ManifestParser,
  version : String,
) -> Unit raise NinjaError {
  let (bin_major, bin_minor) = parse_version(ninja_version)
  let (file_major, file_minor) = parse_version(version)
  if bin_major > file_major {
    self.warnings.push(
      "ninja executable version (\{ninja_version}) greater than build file ninja_required_version (\{version}); versions may be incompatible.",
    )
    return
  }
  if (bin_major == file_major && bin_minor < file_minor) ||
    bin_major < file_major {
    raise Fatal(
      "ninja version (\{ninja_version}) incompatible with build file ninja_required_version version (\{version}).",
    )
  }
}

///|
fn ManifestParser::expect_token(
  self : ManifestParser,
  expected : Token,
) -> Unit raise NinjaError {
  let token = self.lexer.read_token()
  if token != expected {
    raise self.lexer.fail(
      "expected \{expected.name()}, got \{token.name()}\{expected.error_hint()}",
    )
  }
}

///|
fn ManifestParser::parse_let(
  self : ManifestParser,
) -> (String, EvalString) raise NinjaError {
  guard self.lexer.read_ident() is Some(key) else {
    raise self.lexer.fail("expected variable name")
  }
  self.expect_token(Equals)
  (key, self.lexer.read_var_value())
}

///|
fn ManifestParser::parse_pool(self : ManifestParser) -> Unit raise NinjaError {
  guard self.lexer.read_ident() is Some(name) else {
    raise self.lexer.fail("expected pool name")
  }
  self.expect_token(Newline)
  if self.state.lookup_pool(name) is Some(_) {
    raise self.lexer.fail("duplicate pool '\{name}'")
  }
  let mut depth = -1
  while self.lexer.peek_token(Indent) {
    let (key, value) = self.parse_let()
    if key == "depth" {
      depth = atoi(value.evaluate(self.env))
      if depth < 0 {
        raise self.lexer.fail("invalid pool depth")
      }
    } else {
      raise self.lexer.fail("unexpected variable '\{key}'")
    }
  }
  if depth < 0 {
    raise self.lexer.fail("expected 'depth =' line")
  }
  self.state.add_pool(Pool::new(name, depth))
}

///|
fn ManifestParser::parse_rule(self : ManifestParser) -> Unit raise NinjaError {
  guard self.lexer.read_ident() is Some(name) else {
    raise self.lexer.fail("expected rule name")
  }
  self.expect_token(Newline)
  if self.env.lookup_rule_current_scope(name) is Some(_) {
    raise self.lexer.fail("duplicate rule '\{name}'")
  }
  let rule = Rule::new(name)
  while self.lexer.peek_token(Indent) {
    let (key, value) = self.parse_let()
    if is_reserved_binding(key) {
      rule.add_binding(key, value)
    } else {
      // Rules have no scope of their own.
      raise self.lexer.fail("unexpected variable '\{key}'")
    }
  }
  if rule.binding_or_insert("rspfile").is_empty() !=
    rule.binding_or_insert("rspfile_content").is_empty() {
    raise self.lexer.fail(
      "rspfile and rspfile_content need to be both specified",
    )
  }
  if rule.binding_or_insert("command").is_empty() {
    raise self.lexer.fail("expected 'command =' line")
  }
  self.env.add_rule(rule)
}

///|
fn ManifestParser::parse_default(
  self : ManifestParser,
) -> Unit raise NinjaError {
  let mut eval = self.lexer.read_path()
  if eval.is_empty() {
    raise self.lexer.fail("expected target name")
  }
  while !eval.is_empty() {
    let path = eval.evaluate(self.env)
    if path == "" {
      raise self.lexer.fail("empty path")
    }
    let (path, _) = canonicalize_path(path, platform=self.state.platform)
    self.state.add_default(path) catch {
      error => raise self.lexer.fail(error.message())
    }
    eval = self.lexer.read_path()
  }
  self.expect_token(Newline)
}

///|
/// Reads paths until an empty one.
fn ManifestParser::read_paths(
  self : ManifestParser,
  into : Array[EvalString],
) -> Int32 raise NinjaError {
  let mut count = 0
  while true {
    let path = self.lexer.read_path()
    if path.is_empty() {
      break
    }
    into.push(path)
    count += 1
  }
  count
}

///|
fn ManifestParser::canonical(
  self : ManifestParser,
  eval : EvalString,
  env : BindingEnv,
) -> (String, UInt64) raise NinjaError {
  let path = eval.evaluate(env)
  if path == "" {
    raise self.lexer.fail("empty path")
  }
  canonicalize_path(path, platform=self.state.platform)
}

///|
fn ManifestParser::parse_edge(self : ManifestParser) -> Unit raise NinjaError {
  let outs : Array[EvalString] = []
  let ins : Array[EvalString] = []
  let validations : Array[EvalString] = []
  ignore(self.read_paths(outs))
  let implicit_outs = if self.lexer.peek_token(Pipe) {
    self.read_paths(outs)
  } else {
    0
  }
  if outs.is_empty() {
    raise self.lexer.fail("expected path")
  }
  self.expect_token(Colon)
  guard self.lexer.read_ident() is Some(rule_name) else {
    raise self.lexer.fail("expected build command name")
  }
  guard self.env.lookup_rule(rule_name) is Some(rule) else {
    raise self.lexer.fail("unknown build rule '\{rule_name}'")
  }
  ignore(self.read_paths(ins))
  let implicit = if self.lexer.peek_token(Pipe) {
    self.read_paths(ins)
  } else {
    0
  }
  let order_only = if self.lexer.peek_token(Pipe2) {
    self.read_paths(ins)
  } else {
    0
  }
  if self.lexer.peek_token(PipeAt) {
    ignore(self.read_paths(validations))
  }
  self.expect_token(Newline)

  // Bindings on edges are rare; only then does the edge get its own scope.
  let mut has_indent = self.lexer.peek_token(Indent)
  let env = if has_indent { BindingEnv::new(parent=self.env) } else { self.env }
  while has_indent {
    let (key, value) = self.parse_let()
    env.add_binding(key, value.evaluate(self.env))
    has_indent = self.lexer.peek_token(Indent)
  }
  let edge = self.state.add_edge(rule)
  edge.env = env
  let pool_name = edge.get_binding("pool")
  if pool_name != "" {
    guard self.state.lookup_pool(pool_name) is Some(pool) else {
      raise self.lexer.fail("unknown pool name '\{pool_name}'")
    }
    edge.pool = pool
  }
  for out in outs {
    let (path, slash_bits) = self.canonical(out, env)
    self.state.add_out(edge, path, slash_bits) catch {
      error => raise self.lexer.fail(error.message())
    }
  }
  if edge.outputs.is_empty() {
    // Every output is produced by another edge already; drop this one
    // before connecting its inputs.
    ignore(self.state.edges.pop())
    return
  }
  edge.implicit_outs = implicit_outs
  for input in ins {
    let (path, slash_bits) = self.canonical(input, env)
    self.state.add_in(edge, path, slash_bits)
  }
  edge.implicit_deps = implicit
  edge.order_only_deps = order_only
  for validation in validations {
    let (path, slash_bits) = self.canonical(validation, env)
    self.state.add_validation(edge, path, slash_bits)
  }
  if self.options.phony_cycle_action is Warn &&
    edge.maybe_phonycycle_diagnostic() {
    // The output keeps the edge among its out-edges, as in ninja.
    let out = edge.outputs[0]
    let before = edge.inputs.length()
    edge.inputs.retain(fn(node) { !physical_equal(node, out) })
    if edge.inputs.length() != before && !self.quiet {
      self.warnings.push(
        "phony target '\{out.path}' names itself as an input; ignoring [-w phonycycle=warn]",
      )
    }
  }
  // A dyndep file is loaded later, but it must be one of the inputs.
  let dyndep = edge.get_unescaped_dyndep()
  if dyndep != "" {
    let (path, slash_bits) = canonicalize_path(
      dyndep,
      platform=self.state.platform,
    )
    let node = self.state.get_node(path, slash_bits)
    node.dyndep_pending = true
    edge.dyndep = Some(node)
    if !edge.inputs.iter().any(fn(input) { physical_equal(input, node) }) {
      raise self.lexer.fail("dyndep '\{path}' is not an input")
    }
  }
}

///|
fn ManifestParser::parse_file_include(
  self : ManifestParser,
  new_scope : Bool,
) -> Unit raise NinjaError {
  let eval = self.lexer.read_path()
  let path = eval.evaluate(self.env)
  let env = if new_scope { BindingEnv::new(parent=self.env) } else { self.env }
  self.subparser(env).load(path, parent=self.lexer)
  self.expect_token(Newline)
}
