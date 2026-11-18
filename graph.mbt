///|
/// A pool limits how many of its edges run at once; depth 0 is unlimited.
pub struct Pool {
  name : String
  depth : Int32
}

///|
pub fn Pool::new(name : String, depth : Int32) -> Pool {
  { name, depth, }
}

///|
pub fn Pool::name(self : Pool) -> String {
  self.name
}

///|
pub fn Pool::depth(self : Pool) -> Int32 {
  self.depth
}

///|
/// A file in the build graph.
pub struct Node {
  path : String
  /// Which separators were backslashes on Windows (see `canonicalize_path`).
  slash_bits : UInt64
  /// The edge that produces this file, if any.
  mut in_edge : Edge?
  /// Edges that use this file as an input.
  out_edges : Array[Edge]
  /// Edges that use this file as a validation.
  validation_out_edges : Array[Edge]
  mut generated_by_dep_loader : Bool
  mut dyndep_pending : Bool
  /// Index in the deps log, -1 if the node is not in it.
  mut id : Int32
}

///|
pub fn Node::new(path : String, slash_bits : UInt64) -> Node {
  {
    path,
    slash_bits,
    in_edge: None,
    out_edges: [],
    validation_out_edges: [],
    generated_by_dep_loader: true,
    dyndep_pending: false,
    id: -1,
  }
}

///|
pub fn Node::path(self : Node) -> String {
  self.path
}

///|
pub fn Node::slash_bits(self : Node) -> UInt64 {
  self.slash_bits
}

///|
pub fn Node::in_edge(self : Node) -> Edge? {
  self.in_edge
}

///|
pub fn Node::out_edges(self : Node) -> Array[Edge] {
  self.out_edges
}

///|
pub fn Node::id(self : Node) -> Int32 {
  self.id
}

///|
pub fn Node::dyndep_pending(self : Node) -> Bool {
  self.dyndep_pending
}

///|
/// The path with its original separators.
pub fn Node::path_decanonicalized(self : Node, platform : Platform) -> String {
  decanonicalize_path(self.path, self.slash_bits, platform~)
}

///|
/// A build statement. Inputs are ordered explicit, implicit, then
/// order-only; outputs are ordered explicit, then implicit.
pub struct Edge {
  id : Int32
  rule : Rule
  mut pool : Pool
  inputs : Array[Node]
  outputs : Array[Node]
  validations : Array[Node]
  mut env : BindingEnv
  mut implicit_deps : Int32
  mut order_only_deps : Int32
  mut implicit_outs : Int32
  mut dyndep : Node?
  platform : Platform
}

///|
pub fn Edge::rule(self : Edge) -> Rule {
  self.rule
}

///|
pub fn Edge::pool(self : Edge) -> Pool {
  self.pool
}

///|
pub fn Edge::inputs(self : Edge) -> Array[Node] {
  self.inputs
}

///|
pub fn Edge::outputs(self : Edge) -> Array[Node] {
  self.outputs
}

///|
pub fn Edge::validations(self : Edge) -> Array[Node] {
  self.validations
}

///|
pub fn Edge::dyndep(self : Edge) -> Node? {
  self.dyndep
}

///|
pub fn Edge::is_phony(self : Edge) -> Bool {
  self.rule.phony
}

///|
pub fn Edge::is_implicit(self : Edge, index : Int32) -> Bool {
  index >= self.inputs.length() - self.order_only_deps - self.implicit_deps &&
  !self.is_order_only(index)
}

///|
pub fn Edge::is_order_only(self : Edge, index : Int32) -> Bool {
  index >= self.inputs.length() - self.order_only_deps
}

///|
pub fn Edge::is_implicit_out(self : Edge, index : Int32) -> Bool {
  index >= self.outputs.length() - self.implicit_outs
}

///|
/// CMake 2.8.12.x and 3.0.x wrote `build a: phony ... a ...`; ninja's
/// phonycycle diagnostic only applies to that form.
pub fn Edge::maybe_phonycycle_diagnostic(self : Edge) -> Bool {
  self.is_phony() &&
  self.outputs.length() == 1 &&
  self.implicit_outs == 0 &&
  self.implicit_deps == 0
}

///|
/// The value of `key` for this edge, with `$in` and `$out` shell-escaped.
pub fn Edge::get_binding(self : Edge, key : String) -> String raise NinjaError {
  Env::lookup_variable(EdgeEnv::new(self, true), key)
}

///|
pub fn Edge::get_binding_bool(
  self : Edge,
  key : String,
) -> Bool raise NinjaError {
  self.get_binding(key) != ""
}

///|
pub fn Edge::get_unescaped_depfile(self : Edge) -> String raise NinjaError {
  Env::lookup_variable(EdgeEnv::new(self, false), "depfile")
}

///|
pub fn Edge::get_unescaped_dyndep(self : Edge) -> String raise NinjaError {
  Env::lookup_variable(EdgeEnv::new(self, false), "dyndep")
}

///|
pub fn Edge::get_unescaped_rspfile(self : Edge) -> String raise NinjaError {
  Env::lookup_variable(EdgeEnv::new(self, false), "rspfile")
}

///|
/// The command line; with `incl_rsp_file`, the response file contents are
/// appended as `;rspfile=...` (this is what the build log hashes).
pub fn Edge::evaluate_command(
  self : Edge,
  incl_rsp_file~ : Bool = false,
) -> String raise NinjaError {
  let command = self.get_binding("command")
  if incl_rsp_file {
    let content = self.get_binding("rspfile_content")
    if content != "" {
      return command + ";rspfile=" + content
    }
  }
  command
}

///|
/// Variable lookup for one edge: `$in`, `$in_newline` and `$out` come from
/// the edge's files, everything else from the edge, its rule and its scope.
priv struct EdgeEnv {
  edge : Edge
  escape : Bool
  /// Rule variables being expanded, to report cycles.
  lookups : Array[String]
  mut recursive : Bool
}

///|
fn EdgeEnv::new(edge : Edge, escape : Bool) -> EdgeEnv {
  { edge, escape, lookups: [], recursive: false, }
}

///|
fn EdgeEnv::path_list(
  self : EdgeEnv,
  nodes : Array[Node],
  count : Int32,
  sep : Char,
) -> String {
  let out = StringBuilder()
  for i in 0..<count {
    if i > 0 {
      out.write_char(sep)
    }
    let path = nodes[i].path_decanonicalized(self.edge.platform)
    if !self.escape {
      out.write_string(path)
    } else if self.edge.platform is Windows {
      win32_escape(path, out)
    } else {
      shell_escape(path, out)
    }
  }
  out.to_string()
}

///|
impl Env for EdgeEnv with fn lookup_variable(self, name) {
  let edge = self.edge
  if name == "in" || name == "in_newline" {
    let explicit = edge.inputs.length() -
      edge.implicit_deps -
      edge.order_only_deps
    return self.path_list(
      edge.inputs,
      explicit,
      if name == "in" {
        ' '
      } else {
        '\n'
      },
    )
  }
  if name == "out" {
    return self.path_list(
      edge.outputs,
      edge.outputs.length() - edge.implicit_outs,
      ' ',
    )
  }
  if self.recursive {
    match self.lookups.search(name) {
      Some(index) => {
        let cycle = StringBuilder()
        for i in index..<self.lookups.length() {
          cycle.write_string(self.lookups[i] + " -> ")
        }
        cycle.write_string(name)
        raise Fatal("cycle in rule variables: \{cycle.to_string()}")
      }
      None => ()
    }
  }
  let eval = edge.rule.get_binding(name)
  let record = self.recursive && eval is Some(_)
  if record {
    self.lookups.push(name)
  }
  // Rule variables rarely refer to each other; only check for cycles after
  // the first lookup.
  self.recursive = true
  let result = edge.env.lookup_with_fallback(name, eval, self)
  if record {
    ignore(self.lookups.pop())
  }
  result
}
