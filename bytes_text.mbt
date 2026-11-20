// Lossless conversion between ninja's byte strings and MoonBit strings.
//
// ninja keeps paths, commands and log records as raw bytes. moonja keeps
// them as UTF-16 strings, so every byte that is not part of valid UTF-8 is
// stored as one lone surrogate in U+DC80..U+DCFF (Python's
// "surrogateescape"). Valid UTF-8 never decodes to a lone surrogate, and
// bytes below 0x80 are always valid, so the mapping is one-to-one and
// `encode_bytes(decode_bytes(b)) == b` for every `b`.

///|
/// The first code unit that marks an escaped byte: byte `b` (0x80..0xFF)
/// is stored as `escape_base + b`.
let escape_base : Int32 = 0xDC00

///|
/// Decodes bytes as UTF-8, keeping every invalid byte as an escape.
pub fn decode_bytes(bytes : BytesView) -> String {
  // The common case: valid UTF-8 has no U+FFFD after lossy decoding (or
  // only ones that were in the input, which the slow path keeps too).
  let fast = @utf8.decode_lossy(bytes)
  if !fast.contains_char('\u{FFFD}') {
    return fast
  }
  let out = StringBuilder(capacity=bytes.length())
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i].to_int()
    if b0 < 0x80 {
      out.write_char(b0.unsafe_to_char())
      i += 1
      continue
    }
    // Unicode Table 3-7: the well-formed sequences.
    let (len, lo, hi) = if b0 >= 0xC2 && b0 <= 0xDF {
      (2, 0x80, 0xBF)
    } else if b0 == 0xE0 {
      (3, 0xA0, 0xBF)
    } else if b0 == 0xED {
      (3, 0x80, 0x9F)
    } else if b0 >= 0xE1 && b0 <= 0xEF {
      (3, 0x80, 0xBF)
    } else if b0 == 0xF0 {
      (4, 0x90, 0xBF)
    } else if b0 >= 0xF1 && b0 <= 0xF3 {
      (4, 0x80, 0xBF)
    } else if b0 == 0xF4 {
      (4, 0x80, 0x8F)
    } else {
      (0, 0, 0)
    }
    let valid = len > 0 &&
      i + len <= n &&
      bytes[i + 1].to_int() >= lo &&
      bytes[i + 1].to_int() <= hi &&
      (len < 3 || is_continuation(bytes[i + 2])) &&
      (len < 4 || is_continuation(bytes[i + 3]))
    if !valid {
      out.write_char((escape_base + b0).unsafe_to_char())
      i += 1
      continue
    }
    let mut code = if len == 2 {
      b0 & 0x1F
    } else if len == 3 {
      b0 & 0x0F
    } else {
      b0 & 0x07
    }
    for k in 1..<len {
      code = (code << 6) | (bytes[i + k].to_int() & 0x3F)
    }
    out.write_char(code.unsafe_to_char())
    i += len
  }
  out.to_string()
}

///|
fn is_continuation(b : Byte) -> Bool {
  b >= b'\x80' && b <= b'\xBF'
}

///|
/// Encodes a string as UTF-8, turning escapes back into their bytes. Any
/// other lone surrogate becomes U+FFFD, as with a UTF-8 encoder.
pub fn encode_bytes(text : StringView) -> Bytes {
  let n = text.length()
  let has_surrogate = for i in 0..<n {
    let c = text.unsafe_get(i).to_int()
    if c >= 0xD800 && c <= 0xDFFF {
      break true
    }
  } nobreak {
    false
  }
  if !has_surrogate {
    return @utf8.encode(text)
  }
  let out = Buffer(capacity=n * 3)
  let mut i = 0
  while i < n {
    let c = text.unsafe_get(i).to_int()
    if c >= 0xD800 && c <= 0xDBFF && i + 1 < n {
      let d = text.unsafe_get(i + 1).to_int()
      if d >= 0xDC00 && d <= 0xDFFF {
        let code = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)
        out.write_char_utf8(code.unsafe_to_char())
        i += 2
        continue
      }
    }
    if c >= escape_base + 0x80 && c <= escape_base + 0xFF {
      out.write_byte((c - escape_base).to_byte())
    } else if c >= 0xD800 && c <= 0xDFFF {
      out.write_char_utf8('\u{FFFD}')
    } else {
      out.write_char_utf8(c.unsafe_to_char())
    }
    i += 1
  }
  out.to_bytes()
}
