///|
/// The build graph: every file, every edge, the pools and the top-level
/// scope.
pub struct State {
  platform : Platform
  paths : Map[String, Node]
  edges : Array[Edge]
  pools : Map[String, Pool]
  bindings : BindingEnv
  defaults : Array[Node]
  /// The implicit pool of edges without `pool =` (unlimited).
  default_pool : Pool
  /// The built-in `console` pool (depth 1).
  console_pool : Pool
}

///|
pub fn State::new(platform~ : Platform = Posix) -> State {
  let default_pool = Pool::new("", 0)
  let console_pool = Pool::new("console", 1)
  let bindings = BindingEnv::new()
  bindings.add_rule(Rule::phony())
  let pools : Map[String, Pool] = Map([])
  pools[""] = default_pool
  pools["console"] = console_pool
  {
    platform,
    paths: Map([]),
    edges: [],
    pools,
    bindings,
    defaults: [],
    default_pool,
    console_pool,
  }
}

///|
pub fn State::platform(self : State) -> Platform {
  self.platform
}

///|
pub fn State::bindings(self : State) -> BindingEnv {
  self.bindings
}

///|
pub fn State::edges(self : State) -> Array[Edge] {
  self.edges
}

///|
pub fn State::add_pool(self : State, pool : Pool) -> Unit {
  self.pools[pool.name] = pool
}

///|
pub fn State::lookup_pool(self : State, name : String) -> Pool? {
  self.pools.get(name)
}

///|
pub fn State::add_edge(self : State, rule : Rule) -> Edge {
  let edge : Edge = {
    id: self.edges.length(),
    rule,
    pool: self.default_pool,
    inputs: [],
    outputs: [],
    validations: [],
    env: self.bindings,
    implicit_deps: 0,
    order_only_deps: 0,
    implicit_outs: 0,
    dyndep: None,
    platform: self.platform,
    mark: VisitNone,
    outputs_ready: false,
    deps_loaded: false,
    deps_missing: false,
    critical_path_weight: -1,
  }
  self.edges.push(edge)
  edge
}

///|
/// The node for a canonical `path`, created on first use.
pub fn State::get_node(
  self : State,
  path : String,
  slash_bits : UInt64,
) -> Node {
  match self.paths.get(path) {
    Some(node) => node
    None => {
      let node = Node::new(path, slash_bits)
      self.paths[path] = node
      node
    }
  }
}

///|
pub fn State::lookup_node(self : State, path : String) -> Node? {
  self.paths.get(path)
}

///|
pub fn State::add_in(
  self : State,
  edge : Edge,
  path : String,
  slash_bits : UInt64,
) -> Unit {
  let node = self.get_node(path, slash_bits)
  node.generated_by_dep_loader = false
  edge.inputs.push(node)
  node.out_edges.push(edge)
}

///|
/// Adds an output; fails if another edge, or this one, already produces it.
pub fn State::add_out(
  self : State,
  edge : Edge,
  path : String,
  slash_bits : UInt64,
) -> Unit raise NinjaError {
  let node = self.get_node(path, slash_bits)
  match node.in_edge {
    Some(other) =>
      if physical_equal(other, edge) {
        raise Error("\{path} is defined as an output multiple times")
      } else {
        raise Error("multiple rules generate \{path}")
      }
    None => ()
  }
  edge.outputs.push(node)
  node.in_edge = Some(edge)
  node.generated_by_dep_loader = false
}

///|
pub fn State::add_validation(
  self : State,
  edge : Edge,
  path : String,
  slash_bits : UInt64,
) -> Unit {
  let node = self.get_node(path, slash_bits)
  edge.validations.push(node)
  node.validation_out_edges.push(edge)
  node.generated_by_dep_loader = false
}

///|
pub fn State::add_default(self : State, path : String) -> Unit raise NinjaError {
  match self.paths.get(path) {
    Some(node) => self.defaults.push(node)
    None => raise Error("unknown target '\{path}'")
  }
}

///|
/// Forgets everything learned by scanning or building, for another scan.
pub fn State::reset(self : State) -> Unit {
  for _, node in self.paths {
    node.reset_state()
  }
  for edge in self.edges {
    edge.outputs_ready = false
    edge.deps_loaded = false
    edge.mark = VisitNone
  }
}

///|
pub fn State::paths(self : State) -> Map[String, Node] {
  self.paths
}

///|
/// Outputs that no edge uses as an input.
pub fn State::root_nodes(self : State) -> Array[Node] raise NinjaError {
  let roots = []
  for edge in self.edges {
    for out in edge.outputs {
      if out.out_edges.is_empty() {
        roots.push(out)
      }
    }
  }
  if !self.edges.is_empty() && roots.is_empty() {
    raise Error("could not determine root nodes of build graph")
  }
  roots
}

///|
/// The `default` targets, or the root nodes when there are none.
pub fn State::default_nodes(self : State) -> Array[Node] raise NinjaError {
  if self.defaults.is_empty() {
    self.root_nodes()
  } else {
    self.defaults
  }
}
