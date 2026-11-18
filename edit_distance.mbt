///|
/// The Levenshtein distance between `s1` and `s2` (ninja's `EditDistance`).
/// Without replacements a substitution costs two edits. When
/// `max_edit_distance` is positive, the search stops early and returns
/// `max_edit_distance + 1` once every alignment is farther than that.
pub fn edit_distance(
  s1 : String,
  s2 : String,
  allow_replacements~ : Bool = true,
  max_edit_distance~ : Int32 = 0,
) -> Int32 {
  // The classic dynamic program, keeping one row: row[x - 1] is the left
  // entry, row[x] the top one and `previous` the top-left one.
  let m = s1.length()
  let n = s2.length()
  let row = Array::makei(n + 1, fn(i) { i })
  for y in 1..<=m {
    row[0] = y
    let mut best_this_row = row[0]
    let mut previous = y - 1
    for x in 1..<=n {
      let old_row = row[x]
      let same = s1.unsafe_get(y - 1) == s2.unsafe_get(x - 1)
      row[x] = if allow_replacements {
        @cmp.minimum(
          previous + (if same { 0 } else { 1 }),
          @cmp.minimum(row[x - 1], row[x]) + 1,
        )
      } else if same {
        previous
      } else {
        @cmp.minimum(row[x - 1], row[x]) + 1
      }
      previous = old_row
      best_this_row = @cmp.minimum(best_this_row, row[x])
    }
    if max_edit_distance != 0 && best_this_row > max_edit_distance {
      return max_edit_distance + 1
    }
  }
  row[n]
}

///|
/// The known path closest to `path`, within 3 edits, for "did you mean"
/// hints (ninja's `State::SpellcheckNode`). Ties go to the earliest node.
pub fn State::spellcheck_node(self : State, path : String) -> Node? {
  let max_distance = 3
  let mut min_distance = max_distance + 1
  let mut result = None
  for candidate, node in self.paths {
    let distance = edit_distance(
      candidate,
      path,
      max_edit_distance=max_distance,
    )
    if distance < min_distance {
      min_distance = distance
      result = Some(node)
    }
  }
  result
}
