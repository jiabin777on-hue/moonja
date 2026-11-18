///|
/// What a dyndep file says about one edge.
pub struct Dyndeps {
  edge : Edge
  mut used : Bool
  mut restat : Bool
  implicit_inputs : Array[Node]
  implicit_outputs : Array[Node]
}

///|
pub fn Dyndeps::restat(self : Dyndeps) -> Bool {
  self.restat
}

///|
pub fn Dyndeps::implicit_inputs(self : Dyndeps) -> Array[Node] {
  self.implicit_inputs
}

///|
pub fn Dyndeps::implicit_outputs(self : Dyndeps) -> Array[Node] {
  self.implicit_outputs
}

///|
/// The contents of a dyndep file, by edge (ninja's `DyndepFile`).
pub struct DyndepFile {
  entries : Map[Int32, Dyndeps]
}

///|
pub fn DyndepFile::new() -> DyndepFile {
  { entries: Map([]), }
}

///|
pub fn DyndepFile::length(self : DyndepFile) -> Int32 {
  self.entries.length()
}

///|
pub fn DyndepFile::get(self : DyndepFile, edge : Edge) -> Dyndeps? {
  self.entries.get(edge.id)
}

///|
/// Parses dyndep files: `ninja_dyndep_version = 1` followed by
/// `build out | implicit-outs: dyndep | implicit-ins` statements for edges
/// that already exist.
pub struct DyndepParser {
  state : State
  read : ((String) -> String raise NinjaError)?
  file : DyndepFile
  mut lexer : Lexer
  /// Dyndep files have no variables of their own.
  env : BindingEnv
}

///|
pub fn[R : FileReader] DyndepParser::new(
  state : State,
  reader : R,
  file : DyndepFile,
) -> DyndepParser {
  {
    state,
    read: Some(fn(path) { reader.read_file(path) }),
    file,
    lexer: Lexer::new(""),
    env: BindingEnv::new(),
  }
}

///|
pub fn DyndepParser::without_files(
  state : State,
  file : DyndepFile,
) -> DyndepParser {
  { state, read: None, file, lexer: Lexer::new(""), env: BindingEnv::new(), }
}

///|
pub fn DyndepParser::load(
  self : DyndepParser,
  filename : String,
) -> Unit raise NinjaError {
  let contents = match self.read {
    Some(read) =>
      read(filename) catch {
        error => raise Error("loading '\{filename}': \{error.message()}")
      }
    None => raise Error("loading '\{filename}': No such file or directory")
  }
  self.parse(filename, contents)
}

///|
pub fn DyndepParser::parse_test(
  self : DyndepParser,
  input : String,
) -> Unit raise NinjaError {
  self.parse("input", input)
}

///|
pub fn DyndepParser::parse(
  self : DyndepParser,
  filename : String,
  input : String,
) -> Unit raise NinjaError {
  self.lexer = Lexer::new(input, filename~)
  // The version must come first, before any syntax it might not know.
  let mut have_version = false
  while true {
    let token = self.lexer.read_token()
    match token {
      Build => {
        if !have_version {
          raise self.lexer.fail("expected 'ninja_dyndep_version = ...'")
        }
        self.parse_edge()
      }
      Ident => {
        self.lexer.unread_token()
        if have_version {
          raise self.lexer.fail("unexpected \{token.name()}")
        }
        self.parse_dyndep_version()
        have_version = true
      }
      Error => raise self.lexer.fail(self.lexer.describe_last_error())
      Eof => {
        if !have_version {
          raise self.lexer.fail("expected 'ninja_dyndep_version = ...'")
        }
        return
      }
      Newline => ()
      _ => raise self.lexer.fail("unexpected \{token.name()}")
    }
  }
}

///|
fn DyndepParser::parse_let(
  self : DyndepParser,
) -> (String, EvalString) raise NinjaError {
  guard self.lexer.read_ident() is Some(key) else {
    raise self.lexer.fail("expected variable name")
  }
  let token = self.lexer.read_token()
  if token != Equals {
    raise self.lexer.fail(
      "expected \{Equals.name()}, got \{token.name()}\{Equals.error_hint()}",
    )
  }
  (key, self.lexer.read_var_value())
}

///|
fn DyndepParser::expect_token(
  self : DyndepParser,
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
fn DyndepParser::parse_dyndep_version(
  self : DyndepParser,
) -> Unit raise NinjaError {
  let (name, value) = self.parse_let()
  if name != "ninja_dyndep_version" {
    raise self.lexer.fail("expected 'ninja_dyndep_version = ...'")
  }
  let version = value.evaluate(self.env)
  let (major, minor) = parse_version(version)
  if major != 1 || minor != 0 {
    raise self.lexer.fail("unsupported 'ninja_dyndep_version = \{version}'")
  }
}

///|
fn DyndepParser::read_paths(
  self : DyndepParser,
) -> Array[EvalString] raise NinjaError {
  let paths = []
  while true {
    let path = self.lexer.read_path()
    if path.is_empty() {
      break
    }
    paths.push(path)
  }
  paths
}

///|
fn DyndepParser::nodes(
  self : DyndepParser,
  paths : Array[EvalString],
  into : Array[Node],
) -> Unit raise NinjaError {
  for eval in paths {
    let path = eval.evaluate(self.env)
    if path == "" {
      raise self.lexer.fail("empty path")
    }
    let (path, slash_bits) = canonicalize_path(
      path,
      platform=self.state.platform,
    )
    into.push(self.state.get_node(path, slash_bits))
  }
}

///|
fn DyndepParser::parse_edge(self : DyndepParser) -> Unit raise NinjaError {
  // One explicit output, which must already have an edge.
  let out0 = self.lexer.read_path()
  if out0.is_empty() {
    raise self.lexer.fail("expected path")
  }
  let path = out0.evaluate(self.env)
  if path == "" {
    raise self.lexer.fail("empty path")
  }
  let (path, _) = canonicalize_path(path, platform=self.state.platform)
  guard self.state.lookup_node(path) is Some(node) && node.in_edge is Some(edge) else {
    raise self.lexer.fail("no build statement exists for '\{path}'")
  }
  if self.file.entries.contains(edge.id) {
    raise self.lexer.fail("multiple statements for '\{path}'")
  }
  let dyndeps : Dyndeps = {
    edge,
    used: false,
    restat: false,
    implicit_inputs: [],
    implicit_outputs: [],
  }
  self.file.entries[edge.id] = dyndeps
  if !self.lexer.read_path().is_empty() {
    raise self.lexer.fail("explicit outputs not supported")
  }
  let outs = if self.lexer.peek_token(Pipe) { self.read_paths() } else { [] }
  self.expect_token(Colon)
  guard self.lexer.read_ident() is Some("dyndep") else {
    raise self.lexer.fail("expected build command name 'dyndep'")
  }
  if !self.lexer.read_path().is_empty() {
    raise self.lexer.fail("explicit inputs not supported")
  }
  let ins = if self.lexer.peek_token(Pipe) { self.read_paths() } else { [] }
  if self.lexer.peek_token(Pipe2) {
    raise self.lexer.fail("order-only inputs not supported")
  }
  self.expect_token(Newline)
  if self.lexer.peek_token(Indent) {
    let (key, value) = self.parse_let()
    if key != "restat" {
      raise self.lexer.fail("binding is not 'restat'")
    }
    dyndeps.restat = value.evaluate(self.env) != ""
  }
  self.nodes(ins, dyndeps.implicit_inputs)
  self.nodes(outs, dyndeps.implicit_outputs)
}

///|
/// Loads the dyndep file `node` and adds what it says to the edges that
/// name it in their `dyndep` binding. The file's contents go to `file`.
pub fn[R : FileReader] load_dyndeps(
  state : State,
  reader : R,
  node : Node,
  file~ : DyndepFile = DyndepFile::new(),
) -> Unit raise NinjaError {
  // The file is no longer pending once loaded.
  node.dyndep_pending = false
  DyndepParser::new(state, reader, file).load(node.path)
  for edge in node.out_edges {
    match edge.dyndep {
      Some(dyndep) if physical_equal(dyndep, node) => ()
      _ => continue
    }
    guard file.entries.get(edge.id) is Some(dyndeps) else {
      raise Error(
        "'\{edge.outputs[0].path}' not mentioned in its dyndep file '\{node.path}'",
      )
    }
    dyndeps.used = true
    update_edge(edge, dyndeps)
  }
  // Reject outputs the file mentions for edges without this dyndep binding.
  let unused = file.entries.values().filter(fn(d) { !d.used }).collect()
  unused.sort_by(fn(a, b) { a.edge.id.compare(b.edge.id) })
  if unused is [first, ..] {
    raise Error(
      "dyndep file '\{node.path}' mentions output '\{first.edge.outputs[0].path}' whose build statement does not have a dyndep binding for the file",
    )
  }
}

///|
fn update_edge(edge : Edge, dyndeps : Dyndeps) -> Unit raise NinjaError {
  // The edge has its own scope, since it has a dyndep binding.
  if dyndeps.restat {
    edge.env.add_binding("restat", "1")
  }
  for node in dyndeps.implicit_outputs {
    edge.outputs.push(node)
  }
  edge.implicit_outs += dyndeps.implicit_outputs.length()
  for node in dyndeps.implicit_outputs {
    if node.in_edge is Some(_) {
      raise Error("multiple rules generate \{node.path}")
    }
    node.in_edge = Some(edge)
  }
  let at = edge.inputs.length() - edge.order_only_deps
  for i, node in dyndeps.implicit_inputs {
    edge.inputs.insert(at + i, node)
  }
  edge.implicit_deps += dyndeps.implicit_inputs.length()
  for node in dyndeps.implicit_inputs {
    node.out_edges.push(edge)
  }
}
