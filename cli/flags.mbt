///|
/// When a subtool runs (ninja's `Tool::When`).
#derive(Eq, Debug)
pub(all) enum ToolWhen {
  /// Right after the flags, without a manifest.
  AfterFlags
  /// After the manifest is loaded.
  AfterLoad
  /// After the build and deps logs are loaded too.
  AfterLogs
}

///|
#derive(Eq, Debug)
pub(all) struct ToolInfo {
  name : String
  /// None hides the tool from `-t list`.
  description : String?
  when : ToolWhen
}

///|
/// ninja's subtools, in `-t list` order.
pub fn tools(platform : @moonja.Platform) -> Array[ToolInfo] {
  let windows = platform is Windows
  let list = [
    {
      name: "browse",
      description: Some("browse dependency graph in a web browser"),
      when: AfterLoad,
    },
  ]
  if windows {
    list.push({
      name: "msvc",
      description: Some("build helper for MSVC cl.exe (DEPRECATED)"),
      when: AfterFlags,
    })
  }
  list.push_iter(
    [
      {
        name: "clean",
        description: Some("clean built files"),
        when: AfterLoad,
      },
      {
        name: "commands",
        description: Some("list all commands required to rebuild given targets"),
        when: AfterLoad,
      },
      {
        name: "inputs",
        description: Some("list all inputs required to rebuild given targets"),
        when: AfterLoad,
      },
      {
        name: "multi-inputs",
        description: Some(
          "print one or more sets of inputs required to build targets",
        ),
        when: AfterLoad,
      },
      {
        name: "deps",
        description: Some("show dependencies stored in the deps log"),
        when: AfterLogs,
      },
      {
        name: "missingdeps",
        description: Some("check deps log dependencies on generated files"),
        when: AfterLogs,
      },
      {
        name: "graph",
        description: Some("output graphviz dot file for targets"),
        when: AfterLoad,
      },
      {
        name: "query",
        description: Some("show inputs/outputs for a path"),
        when: AfterLogs,
      },
      {
        name: "targets",
        description: Some("list targets by their rule or depth in the DAG"),
        when: AfterLoad,
      },
      {
        name: "compdb",
        description: Some("dump JSON compilation database to stdout"),
        when: AfterLoad,
      },
      {
        name: "compdb-targets",
        description: Some(
          "dump JSON compilation database for a given list of targets to stdout",
        ),
        when: AfterLoad,
      },
      {
        name: "recompact",
        description: Some("recompacts ninja-internal data structures"),
        when: AfterLoad,
      },
      {
        name: "restat",
        description: Some("restats all outputs in the build log"),
        when: AfterFlags,
      },
      { name: "rules", description: Some("list all rules"), when: AfterLoad, },
      {
        name: "cleandead",
        description: Some(
          "clean built files that are no longer produced by the manifest",
        ),
        when: AfterLogs,
      },
      { name: "urtle", description: None, when: AfterFlags, },
    ].iter(),
  )
  if windows {
    list.push({
      name: "wincodepage",
      description: Some("print the Windows code page used by ninja"),
      when: AfterFlags,
    })
  }
  list
}

///|
/// The parsed command line (ninja's `Options` plus its `BuildConfig`).
pub(all) struct Options {
  mut input_file : String
  mut working_dir : String?
  mut tool : ToolInfo?
  mut phony_cycle_should_err : Bool
  /// `-d stats`; accepted, but moonja reports no metrics.
  mut stats : Bool
  /// The argument holding the tool's name (`rules` or `-trules`): the
  /// program name in the tool's own getopt messages.
  mut tool_argv0 : String
  config : @moonja.BuildConfig
  /// Targets, or the tool's arguments.
  args : Array[String]
}

///|
/// The closest word within 3 edits (ninja's `SpellcheckStringV`).
fn spellcheck_string(text : String, words : Array[String]) -> String? {
  let mut min_distance = 4
  let mut result = None
  for word in words {
    let distance = @moonja.edit_distance(word, text, max_edit_distance=3)
    if distance < min_distance {
      min_distance = distance
      result = Some(word)
    }
  }
  result
}

///|
/// The default for `-j` (ninja's `GuessParallelism`).
pub fn guess_parallelism(processors : Int32) -> Int32 {
  match processors {
    0 | 1 => 2
    2 => 3
    n => n + 2
  }
}

///|
let int_max : Int32 = 2147483647

///|
fn usage(host : Host, parallelism : Int32) -> Unit {
  host.terminal.write_err(
    (
      $|usage: ninja [options] [targets...]
      $|
      $|if targets are unspecified, builds the 'default' target (see manual).
      $|
      $|options:
      $|  --version      print ninja version ("\{@moonja.ninja_version}")
      $|  -v, --verbose  show all command lines while building
      $|  --quiet        don't show progress status, just command output
      $|
      $|  -C DIR   change to DIR before doing anything else
      $|  -f FILE  specify input build file [default=build.ninja]
      $|
      $|  -j N     run N jobs in parallel (0 means infinity) [default=\{parallelism} on this system]
      $|  -k N     keep going until N jobs fail (0 means infinity) [default=1]
      $|  -l N     do not start new jobs if the load average is greater than N
      $|  -n       dry run (don't run commands but act like they succeeded)
      $|
      $|  -d MODE  enable debugging (use '-d list' to list modes)
      $|  -t TOOL  run a subtool (use '-t list' to list subtools)
      $|    terminates toplevel options; further flags are passed to the tool
      $|  -w FLAG  adjust warnings (use '-w list' to list warnings)
      $|
    ),
  )
}

///|
fn is_space(c : UInt16) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c == '\u{b}' ||
  c == '\u{c}'
}

///|
/// C's `strtol(text, &end, 10)`: the value of the longest numeric prefix
/// and whether the whole text was consumed.
fn strtol(text : String) -> (Int64, Bool) {
  let len = text.length()
  let mut i = 0
  while i < len && is_space(text.unsafe_get(i)) {
    i += 1
  }
  let mut negative = false
  if i < len && (text.unsafe_get(i) == '+' || text.unsafe_get(i) == '-') {
    negative = text.unsafe_get(i) == '-'
    i += 1
  }
  let digits_start = i
  let mut value = 0L
  while i < len && text.unsafe_get(i) >= '0' && text.unsafe_get(i) <= '9' {
    if value < 1000000000000000000L {
      value = value * 10 +
        (text.unsafe_get(i).to_int() - '0'.to_int()).to_int64()
    }
    i += 1
  }
  if i == digits_start {
    // No number: end is the start of the text.
    return (0, len == 0)
  }
  (if negative { -value } else { value }, i == len)
}

///|
/// C's `strtod`: the value of the longest decimal prefix, or None.
fn strtod(text : String) -> Double? {
  let len = text.length()
  let mut i = 0
  while i < len && is_space(text.unsafe_get(i)) {
    i += 1
  }
  let start = i
  if i < len && (text.unsafe_get(i) == '+' || text.unsafe_get(i) == '-') {
    i += 1
  }
  let mut digits = 0
  while i < len && text.unsafe_get(i) >= '0' && text.unsafe_get(i) <= '9' {
    i += 1
    digits += 1
  }
  if i < len && text.unsafe_get(i) == '.' {
    i += 1
    while i < len && text.unsafe_get(i) >= '0' && text.unsafe_get(i) <= '9' {
      i += 1
      digits += 1
    }
  }
  if digits == 0 {
    return None
  }
  let mantissa_end = i
  if i < len && (text.unsafe_get(i) == 'e' || text.unsafe_get(i) == 'E') {
    let mut j = i + 1
    if j < len && (text.unsafe_get(j) == '+' || text.unsafe_get(j) == '-') {
      j += 1
    }
    let exp_start = j
    while j < len && text.unsafe_get(j) >= '0' && text.unsafe_get(j) <= '9' {
      j += 1
    }
    if j > exp_start {
      i = j
    }
  }
  ignore(mantissa_end)
  let number = text.unsafe_substring(start~, end=i)
  Some(@string.parse_double(number) catch { _ => 0.0 })
}

///|
let debug_modes : Array[String] = [
  "stats", "explain", "keepdepfile", "keeprsp", "nostatcache",
]

///|
/// ninja's `DebugEnable`: false if ninja should exit (with 1).
fn debug_enable(host : Host, name : String, options : Options) -> Bool {
  match name {
    "list" => {
      let nostatcache = if host.platform is Windows {
        "  nostatcache  don't batch stat() calls per directory and cache them\n"
      } else {
        ""
      }
      host.print(
        "debugging modes:\n  stats        print operation counts/timing info\n  explain      explain what caused a command to execute\n  keepdepfile  don't delete depfiles after they're read by ninja\n  keeprsp      don't delete @response files on success\n\{nostatcache}multiple modes can be enabled via -d FOO -d BAR\n",
      )
      false
    }
    "stats" => {
      options.stats = true
      true
    }
    "explain" => {
      options.config.explain = true
      true
    }
    "keepdepfile" => {
      options.config.keep_depfile = true
      true
    }
    "keeprsp" => {
      options.config.keep_rsp = true
      true
    }
    "nostatcache" => true
    _ => {
      match spellcheck_string(name, debug_modes) {
        Some(suggestion) =>
          host.error(
            "unknown debug setting '\{name}', did you mean '\{suggestion}'?",
          )
        None => host.error("unknown debug setting '\{name}'")
      }
      false
    }
  }
}

///|
/// ninja's `WarningEnable`: false if ninja should exit (with 1).
fn warning_enable(host : Host, name : String, options : Options) -> Bool {
  match name {
    "list" => {
      host.print(
        "warning flags:\n  phonycycle={err,warn}  phony build statement references itself\n",
      )
      false
    }
    "phonycycle=err" => {
      options.phony_cycle_should_err = true
      true
    }
    "phonycycle=warn" => {
      options.phony_cycle_should_err = false
      true
    }
    "dupbuild=err" | "dupbuild=warn" => {
      host.warning("deprecated warning 'dupbuild'")
      true
    }
    "depfilemulti=err" | "depfilemulti=warn" => {
      host.warning("deprecated warning 'depfilemulti'")
      true
    }
    _ => {
      match spellcheck_string(name, ["phonycycle=err", "phonycycle=warn"]) {
        Some(suggestion) =>
          host.error(
            "unknown warning flag '\{name}', did you mean '\{suggestion}'?",
          )
        None => host.error("unknown warning flag '\{name}'")
      }
      false
    }
  }
}

///|
/// ninja's `ChooseTool`: None after `-t list`.
fn choose_tool(host : Host, name : String) -> ToolInfo? raise Quit {
  let all = tools(host.platform)
  if name == "list" {
    host.print("ninja subtools:\n")
    for tool in all {
      if tool.description is Some(description) {
        let padded = " ".repeat(@cmp.maximum(0, 11 - tool.name.length())) +
          tool.name
        host.print("\{padded}  \{description}\n")
      }
    }
    return None
  }
  for tool in all {
    if tool.name == name {
      return Some(tool)
    }
  }
  match spellcheck_string(name, all.map(fn(t) { t.name })) {
    Some(suggestion) =>
      host.fatal("unknown tool '\{name}', did you mean '\{suggestion}'?")
    None => host.fatal("unknown tool '\{name}'")
  }
  None
}

///|
let long_options : Array[String] = ["help", "version", "verbose", "quiet"]

///|
/// Short options that take an argument.
fn takes_argument(c : UInt16) -> Bool {
  c == 'd' ||
  c == 'f' ||
  c == 'j' ||
  c == 'k' ||
  c == 'l' ||
  c == 't' ||
  c == 'w' ||
  c == 'C'
}

///|
/// What a flag did: go on, or exit with a code.
priv enum FlagResult {
  Continue
  ExitWith(Int32)
}

///|
fn apply_flag(
  host : Host,
  options : Options,
  flag : UInt16,
  value : String,
  guessed : Int32,
) -> FlagResult raise Quit {
  let config = options.config
  match flag {
    'd' => if !debug_enable(host, value, options) { return ExitWith(1) }
    'f' => options.input_file = value
    'j' => {
      let (n, whole) = strtol(value)
      if !whole || n < 0 {
        host.fatal("invalid -j parameter")
      }
      // 0 means "infinite".
      config.parallelism = if n > 0 && n < int_max.to_int64() {
        n.to_int()
      } else {
        int_max
      }
    }
    'k' => {
      let (n, whole) = strtol(value)
      if !whole {
        host.fatal("-k parameter not numeric; did you mean -k 0?")
      }
      config.failures_allowed = if n > 0 && n < int_max.to_int64() {
        n.to_int()
      } else {
        int_max
      }
    }
    'l' =>
      match strtod(value) {
        Some(load) => config.max_load_average = load
        None => host.fatal("-l parameter not numeric: did you mean -l 0.0?")
      }
    'n' => config.dry_run = true
    't' =>
      match choose_tool(host, value) {
        Some(tool) => options.tool = Some(tool)
        None => return ExitWith(0)
      }
    'v' => config.verbosity = Verbose
    'q' => config.verbosity = NoStatusUpdate
    'w' => if !warning_enable(host, value, options) { return ExitWith(1) }
    'C' => options.working_dir = Some(value)
    'V' => {
      host.print("\{@moonja.ninja_version}\n")
      return ExitWith(0)
    }
    _ => {
      usage(host, guessed)
      return ExitWith(1)
    }
  }
  Continue
}

///|
/// Parses the command line like ninja's `ReadFlags` with glibc's
/// `getopt_long`: options may follow targets, `--` ends options, short
/// options combine (`-nv`, `-j8`), long options may be abbreviated, and
/// `-t TOOL` ends option parsing. Returns the options, or the exit code if
/// ninja should stop.
pub fn read_flags(host : Host, args : Array[String]) -> Result[Options, Int32] {
  let guessed = guess_parallelism(host.processor_count)
  let config = @moonja.BuildConfig::default()
  config.parallelism = guessed
  let options = {
    input_file: "build.ninja",
    working_dir: None,
    tool: None,
    phony_cycle_should_err: false,
    stats: false,
    tool_argv0: "",
    config,
    args: [],
  }
  let result = parse_args(host, args, options, guessed) catch {
    Quit(code) => return Err(code)
  }
  match result {
    Continue => Ok(options)
    ExitWith(code) => Err(code)
  }
}

///|
fn parse_args(
  host : Host,
  args : Array[String],
  options : Options,
  guessed : Int32,
) -> FlagResult raise Quit {
  let positional = []
  let len = args.length()
  let mut i = 0
  while i < len && options.tool is None {
    let arg = args[i]
    i += 1
    if arg == "--" {
      for j in i..<len {
        positional.push(args[j])
      }
      i = len
      break
    }
    // ninja's getopt on Windows reads an unknown long option as short
    // options from its third character (`--bogus` is `-b`...).
    let mut short_start = 1
    if arg.has_prefix("--") &&
      host.platform is Windows &&
      arg.length() > 2 &&
      !long_options
      .iter()
      .any(fn(o) {
        o.has_prefix(arg.unsafe_substring(start=2, end=arg.length()))
      }) {
      short_start = 2
    } else if arg.has_prefix("--") {
      let body = arg.unsafe_substring(start=2, end=arg.length())
      let (name, has_value) = match body.find("=") {
        Some(eq) => (body.unsafe_substring(start=0, end=eq), true)
        None => (body, false)
      }
      let matches = long_options.filter(fn(o) { o.has_prefix(name) })
      let chosen = if long_options.contains(name) {
        Some(name)
      } else if matches.length() == 1 {
        Some(matches[0])
      } else {
        None
      }
      guard chosen is Some(option) else {
        if matches.length() > 1 {
          if host.platform is Windows {
            // ninja's own getopt names the first two candidates.
            host.terminal.write_err(
              "ninja: option `\{arg}' is ambiguous (could be `--\{matches[0]}' or `--\{matches[1]}')\n",
            )
          } else {
            let possibilities = matches.map(fn(m) { " '--\{m}'" }).join("")
            host.terminal.write_err(
              "ninja: option '--\{name}' is ambiguous; possibilities:\{possibilities}\n",
            )
          }
        } else {
          host.terminal.write_err("ninja: unrecognized option '\{arg}'\n")
        }
        usage(host, guessed)
        return ExitWith(1)
      }
      if has_value {
        host.terminal.write_err(
          "ninja: option '--\{option}' doesn't allow an argument\n",
        )
        usage(host, guessed)
        return ExitWith(1)
      }
      let flag : UInt16 = match option {
        "help" => 'h'
        "version" => 'V'
        "verbose" => 'v'
        _ => 'q'
      }
      match apply_flag(host, options, flag, "", guessed) {
        Continue => ()
        exit => return exit
      }
      continue
    }
    if arg.length() > 1 && arg.unsafe_get(0) == '-' {
      let mut j = short_start
      while j < arg.length() {
        let c = arg.unsafe_get(j)
        j += 1
        if takes_argument(c) {
          // ninja's getopt on Windows drops a leading '=' (`-j=4`).
          if host.platform is Windows &&
            j < arg.length() &&
            arg.unsafe_get(j) == '=' {
            j += 1
          }
          let attached = j < arg.length()
          let value = if j < arg.length() {
            arg.unsafe_substring(start=j, end=arg.length())
          } else if i < len {
            i += 1
            args[i - 1]
          } else {
            let flag = c.to_int().unsafe_to_char()
            host.terminal.write_err(
              if host.platform is Windows {
                "ninja: argument required for option `-\{flag}'\n"
              } else {
                "ninja: option requires an argument -- '\{flag}'\n"
              },
            )
            usage(host, guessed)
            return ExitWith(1)
          }
          if c == 't' {
            options.tool_argv0 = if attached { arg } else { value }
          }
          match apply_flag(host, options, c, value, guessed) {
            Continue => ()
            exit => return exit
          }
          break
        }
        if c == 'n' || c == 'v' || c == 'h' {
          match apply_flag(host, options, c, "", guessed) {
            Continue => ()
            exit => return exit
          }
        } else {
          let flag = c.to_int().unsafe_to_char()
          host.terminal.write_err(
            if host.platform is Windows {
              "ninja: invalid option -- `-\{flag}'\n"
            } else {
              "ninja: invalid option -- '\{flag}'\n"
            },
          )
          usage(host, guessed)
          return ExitWith(1)
        }
      }
      continue
    }
    positional.push(arg)
  }
  if options.tool is Some(_) {
    // getopt stops at the tool; what follows is the tool's. Targets seen
    // before `-t` are dropped, as with glibc.
    for j in i..<len {
      options.args.push(args[j])
    }
  } else {
    options.args.push_iter(positional.iter())
  }
  Continue
}
