///|
test "erase_entries moves the last entry into each hole, as emhash8 does" {
  let log = BuildLog::new()
  for output in ["d1", "g1", "d2", "d3", "g2", "d4", "d5", "g3", "d6", "kept"] {
    log.entries[output] = {
      output,
      command_hash: 0,
      start_time: 0,
      end_time: 0,
      mtime: 0,
    }
  }
  log.erase_entries(["g1", "g2", "g3", "missing"])
  let order = StringBuilder()
  for output, _ in log.entries {
    order.write_string(output + " ")
  }
  inspect(order.to_string(), content="d1 kept d2 d3 d6 d4 d5 ")
}

///|
/// One UInt64 multiply per digit: what parse_c_integer computes, chunked.
fn parse_c_integer_reference(text : String, base : Int32) -> UInt64 {
  let mut i = 0
  let end = text.length()
  while i < end && (text.unsafe_get(i) == ' ' || text.unsafe_get(i) == '\t') {
    i += 1
  }
  let mut negative = false
  if i < end && (text.unsafe_get(i) == '-' || text.unsafe_get(i) == '+') {
    negative = text.unsafe_get(i) == '-'
    i += 1
  }
  if base == 16 &&
    i + 1 < end &&
    text.unsafe_get(i) == '0' &&
    (text.unsafe_get(i + 1) == 'x' || text.unsafe_get(i + 1) == 'X') {
    i += 2
  }
  let mut value : UInt64 = 0
  while i < end {
    let c = text.unsafe_get(i).to_int()
    let digit = if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else if base == 16 && c >= 'a'.to_int() && c <= 'f'.to_int() {
      c - 'a'.to_int() + 10
    } else if base == 16 && c >= 'A'.to_int() && c <= 'F'.to_int() {
      c - 'A'.to_int() + 10
    } else {
      break
    }
    value = value * base.to_uint64() + digit.to_uint64()
    i += 1
  }
  if negative {
    0UL - value
  } else {
    value
  }
}

///|
test "parse_c_integer agrees with digit-by-digit parsing" {
  let chars = "0123456789abcdefABCDEF-+ x\tg"
  let fixed = [
    "", "0", "18446744073709551615", "18446744073709551616", "99999999999999999999999",
    "-1", "+42", "  7", "1795426327968716000", "0x7c58058fd94c137f", "ffffffffffffffff",
    "10000000000000000", "12345678", "123456789", "1234567x89", "fffffff", "ffffffff",
  ]
  let inputs = []
  for s in fixed {
    inputs.push(s)
  }
  // A fixed linear congruential sequence: the same inputs on every run.
  let mut seed = 12345
  let next = fn(n : Int32) -> Int32 {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    seed % n
  }
  for _ in 0..<3000 {
    let len = next(26)
    let digits_only = next(2) == 0
    let sb = StringBuilder()
    for _ in 0..<len {
      let pool = if digits_only { 22 } else { chars.length() }
      sb.write_char(
        Int32::unsafe_to_char(chars.unsafe_get(next(pool)).to_int()),
      )
    }
    inputs.push(sb.to_string())
  }
  for s in inputs {
    for base in [10, 16] {
      let got = parse_c_integer(s, 0, s.length(), base)
      let want = parse_c_integer_reference(s, base)
      if got != want {
        fail("\{s} base \{base}: \{got} vs \{want}")
      }
    }
  }
}
