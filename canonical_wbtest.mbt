///|
/// The shortcut in canonicalize_path must not change any result: every
/// string over a / . \ up to length 7, on both platforms.
test "canonicalize_path shortcut agrees with the full algorithm" {
  let alphabet = ["a", "/", ".", "\\"]
  let mut paths = [""]
  let mut checked = 0
  for _ in 0..<7 {
    let next = []
    for p in paths {
      for c in alphabet {
        next.push(p + c)
      }
    }
    for p in next {
      for windows in [false, true] {
        let platform = if windows { Windows } else { Posix }
        let fast = canonicalize_path(p, platform~)
        let full = canonicalize_path_copy(p, platform)
        if fast != full {
          fail("\{p} (windows: \{windows}): \{fast.0} vs \{full.0}")
        }
        checked += 1
      }
    }
    paths = next
  }
  assert_eq(checked, 2 * (4 + 16 + 64 + 256 + 1024 + 4096 + 16384))
}
