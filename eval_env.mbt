///|
/// A scope for `$var` lookups.
pub(open) trait Env {
  fn lookup_variable(Self, String) -> String raise NinjaError
}

///|
#derive(Eq, Debug)
pub(all) enum EvalToken {
  /// Literal text.
  Raw(String)
  /// A `$var` reference.
  Special(String)
}

///|
/// A manifest string with unexpanded variable references.
pub struct EvalString {
  tokens : Array[EvalToken]
}

///|
pub fn EvalString::new() -> EvalString {
  { tokens: [], }
}

///|
pub fn EvalString::is_empty(self : EvalString) -> Bool {
  self.tokens.is_empty()
}

///|
pub fn EvalString::clear(self : EvalString) -> Unit {
  self.tokens.clear()
}

///|
pub fn EvalString::add_text(self : EvalString, text : String) -> Unit {
  if text == "" {
    return
  }
  match self.tokens.last() {
    Some(Raw(previous)) =>
      self.tokens[self.tokens.length() - 1] = Raw(previous + text)
    _ => self.tokens.push(Raw(text))
  }
}

///|
pub fn EvalString::add_special(self : EvalString, name : String) -> Unit {
  self.tokens.push(Special(name))
}

///|
/// Expands the variable references in `env`.
pub fn[E : Env] EvalString::evaluate(
  self : EvalString,
  env : E,
) -> String raise NinjaError {
  match self.tokens {
    [] => ""
    [Raw(text)] => text
    tokens => {
      let out = StringBuilder()
      for token in tokens {
        match token {
          Raw(text) => out.write_string(text)
          Special(name) => out.write_string(env.lookup_variable(name))
        }
      }
      out.to_string()
    }
  }
}

///|
/// The parsed form, for tests: `[text][$var]`.
pub fn EvalString::serialize(self : EvalString) -> String {
  let out = StringBuilder()
  for token in self.tokens {
    match token {
      Raw(text) => out.write_string("[\{text}]")
      Special(name) => out.write_string("[$\{name}]")
    }
  }
  out.to_string()
}

///|
/// The string with references written as `${var}`.
pub fn EvalString::unparse(self : EvalString) -> String {
  let out = StringBuilder()
  for token in self.tokens {
    match token {
      Raw(text) => out.write_string(text)
      Special(name) => out.write_string("${\{name}}")
    }
  }
  out.to_string()
}

///|
/// A build rule: its name and its unexpanded bindings.
pub struct Rule {
  name : String
  bindings : Map[String, EvalString]
  phony : Bool
}

///|
pub fn Rule::new(name : String) -> Rule {
  { name, bindings: Map([]), phony: false, }
}

///|
/// The built-in `phony` rule.
pub fn Rule::phony() -> Rule {
  { name: "phony", bindings: Map([]), phony: true, }
}

///|
pub fn Rule::name(self : Rule) -> String {
  self.name
}

///|
pub fn Rule::is_phony(self : Rule) -> Bool {
  self.phony
}

///|
pub fn Rule::add_binding(self : Rule, key : String, value : EvalString) -> Unit {
  self.bindings[key] = value
}

///|
pub fn Rule::get_binding(self : Rule, key : String) -> EvalString? {
  self.bindings.get(key)
}

///|
/// The binding for `key`, creating an empty one when there is none, like
/// `std::map::operator[]` in ninja's parser. The empty binding matters: it
/// hides a same-named variable of the enclosing scope from the rule's edges.
fn Rule::binding_or_insert(self : Rule, key : String) -> EvalString {
  match self.bindings.get(key) {
    Some(value) => value
    None => {
      let value = EvalString::new()
      self.bindings[key] = value
      value
    }
  }
}

///|
/// The variables a rule may set.
pub fn is_reserved_binding(name : String) -> Bool {
  name
  is ("command"
  | "depfile"
  | "dyndep"
  | "description"
  | "deps"
  | "generator"
  | "pool"
  | "restat"
  | "rspfile"
  | "rspfile_content"
  | "msvc_deps_prefix")
}

///|
/// A variable scope with rules, nested in an optional parent scope.
pub struct BindingEnv {
  bindings : Map[String, String]
  rules : Map[String, Rule]
  parent : BindingEnv?
}

///|
pub fn BindingEnv::new(parent? : BindingEnv) -> BindingEnv {
  { bindings: Map([]), rules: Map([]), parent, }
}

///|
pub impl Env for BindingEnv with fn lookup_variable(self, name) {
  self.lookup(name)
}

///|
/// The value of `name` in this scope or the nearest enclosing one.
pub fn BindingEnv::lookup(self : BindingEnv, name : String) -> String {
  match self.bindings.get(name) {
    Some(value) => value
    None =>
      match self.parent {
        Some(parent) => parent.lookup(name)
        None => ""
      }
  }
}

///|
pub fn BindingEnv::add_binding(
  self : BindingEnv,
  key : String,
  value : String,
) -> Unit {
  self.bindings[key] = value
}

///|
pub fn BindingEnv::add_rule(self : BindingEnv, rule : Rule) -> Unit {
  self.rules[rule.name] = rule
}

///|
pub fn BindingEnv::lookup_rule_current_scope(
  self : BindingEnv,
  name : String,
) -> Rule? {
  self.rules.get(name)
}

///|
pub fn BindingEnv::lookup_rule(self : BindingEnv, name : String) -> Rule? {
  match self.rules.get(name) {
    Some(rule) => Some(rule)
    None =>
      match self.parent {
        Some(parent) => parent.lookup_rule(name)
        None => None
      }
  }
}

///|
/// The rules of this scope, ordered by name.
pub fn BindingEnv::rules(self : BindingEnv) -> Array[Rule] {
  let rules = self.rules.values().collect()
  rules.sort_by(fn(a, b) { compare_lexical(a.name, b.name) })
  rules
}

///|
/// Edges look a variable up in this order: (1) the edge's own bindings
/// (`self`), (2) the rule's binding `eval`, expanded in `env`, (3) the
/// scope enclosing the edge.
pub fn[E : Env] BindingEnv::lookup_with_fallback(
  self : BindingEnv,
  name : String,
  eval : EvalString?,
  env : E,
) -> String raise NinjaError {
  match self.bindings.get(name) {
    Some(value) => value
    None =>
      match eval {
        Some(eval) => eval.evaluate(env)
        None =>
          match self.parent {
            Some(parent) => parent.lookup(name)
            None => ""
          }
      }
  }
}
