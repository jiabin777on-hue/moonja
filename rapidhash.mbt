// rapidhash v1 (https://github.com/Nicoshev/rapidhash, BSD-2-Clause), as
// vendored by ninja v1.13.2 in src/third_party/rapidhash/rapidhash.h with
// RAPIDHASH_FAST and RAPIDHASH_UNROLLED. ninja's build log (format v7)
// stores this hash of each command, so moonja must match it bit for bit.
//
// 64-bit values are kept as two 32-bit halves and the 128-bit products are
// built from 16-bit pieces, so no step needs UInt64: on the JS backend that
// is a BigInt, and a no-op build hashes every command. rapidhash_wbtest.mbt
// checks this against the plain UInt64 version.

///|
/// A 64-bit value as its high and low 32 bits.
priv struct W64 {
  hi : UInt32
  lo : UInt32
}

///|
fn W64::xor(a : W64, b : W64) -> W64 {
  { hi: a.hi ^ b.hi, lo: a.lo ^ b.lo, }
}

///|
let rapid_seed : W64 = { hi: 0xbdd89aa9U, lo: 0x82704029U, }

///|
let rapid_secret0 : W64 = { hi: 0x2d358dccU, lo: 0xaa6c78a5U, }

///|
let rapid_secret1 : W64 = { hi: 0x8bb84b93U, lo: 0x962eacc9U, }

///|
let rapid_secret2 : W64 = { hi: 0x4b33a62eU, lo: 0xd433d4a3U, }

///|
/// The 64-bit product of two 32-bit values, from 16-bit pieces (each
/// partial product fits in 32 bits).
fn rapid_mul32(x : UInt32, y : UInt32) -> W64 {
  let x0 = x & 0xffff
  let x1 = x >> 16
  let y0 = y & 0xffff
  let y1 = y >> 16
  let p00 = x0 * y0
  let p01 = x0 * y1
  let p10 = x1 * y0
  let p11 = x1 * y1
  let mid = (p00 >> 16) + (p01 & 0xffff) + (p10 & 0xffff)
  {
    hi: p11 + (p01 >> 16) + (p10 >> 16) + (mid >> 16),
    lo: (mid << 16) | (p00 & 0xffff),
  }
}

///|
fn carry(sum : UInt32, addend : UInt32) -> UInt32 {
  if sum < addend {
    1
  } else {
    0
  }
}

///|
/// The full 128-bit product of `a` and `b` as (low, high).
fn rapid_mum(a : W64, b : W64) -> (W64, W64) {
  let ll = rapid_mul32(a.lo, b.lo)
  let lh = rapid_mul32(a.lo, b.hi)
  let hl = rapid_mul32(a.hi, b.lo)
  let hh = rapid_mul32(a.hi, b.hi)
  // Bits 32..63: ll.hi + lh.lo + hl.lo.
  let t1 = ll.hi + lh.lo
  let w1 = t1 + hl.lo
  let c1 = carry(t1, ll.hi) + carry(w1, t1)
  // Bits 64..95: lh.hi + hl.hi + hh.lo + c1.
  let t2 = lh.hi + hl.hi
  let t3 = t2 + hh.lo
  let w2 = t3 + c1
  let c2 = carry(t2, lh.hi) + carry(t3, t2) + carry(w2, t3)
  ({ hi: w1, lo: ll.lo, }, { hi: hh.hi + c2, lo: w2, })
}

///|
fn rapid_mix(a : W64, b : W64) -> W64 {
  let (lo, hi) = rapid_mum(a, b)
  lo.xor(hi)
}

///|
/// The little-endian 32-bit word at `i`.
fn rapid_word32(p : Bytes, i : Int32) -> UInt32 {
  p[i].to_uint() |
  (p[i + 1].to_uint() << 8) |
  (p[i + 2].to_uint() << 16) |
  (p[i + 3].to_uint() << 24)
}

///|
fn rapid_read64(p : Bytes, i : Int32) -> W64 {
  { hi: rapid_word32(p, i + 4), lo: rapid_word32(p, i), }
}

///|
/// rapidhash of `key` with ninja's default seed.
pub fn rapidhash(key : Bytes) -> UInt64 {
  let len = key.length()
  let len64 : W64 = { hi: 0, lo: len.reinterpret_as_uint(), }
  let mut seed = rapid_seed
  seed = seed.xor(rapid_mix(seed.xor(rapid_secret0), rapid_secret1)).xor(len64)
  let mut a : W64 = { hi: 0, lo: 0, }
  let mut b : W64 = { hi: 0, lo: 0, }
  if len <= 16 {
    if len >= 4 {
      let last = len - 4
      a = { hi: rapid_word32(key, 0), lo: rapid_word32(key, last), }
      let delta = (len & 24) >> (len >> 3)
      b = { hi: rapid_word32(key, delta), lo: rapid_word32(key, last - delta), }
    } else if len > 0 {
      a = {
        hi: (key[0].to_uint() << 24) | key[len >> 1].to_uint(),
        lo: key[len - 1].to_uint(),
      }
    }
  } else {
    let mut p = 0
    let mut i = len
    if i > 48 {
      let mut see1 = seed
      let mut see2 = seed
      while i >= 96 {
        seed = rapid_mix(
          rapid_read64(key, p).xor(rapid_secret0),
          rapid_read64(key, p + 8).xor(seed),
        )
        see1 = rapid_mix(
          rapid_read64(key, p + 16).xor(rapid_secret1),
          rapid_read64(key, p + 24).xor(see1),
        )
        see2 = rapid_mix(
          rapid_read64(key, p + 32).xor(rapid_secret2),
          rapid_read64(key, p + 40).xor(see2),
        )
        seed = rapid_mix(
          rapid_read64(key, p + 48).xor(rapid_secret0),
          rapid_read64(key, p + 56).xor(seed),
        )
        see1 = rapid_mix(
          rapid_read64(key, p + 64).xor(rapid_secret1),
          rapid_read64(key, p + 72).xor(see1),
        )
        see2 = rapid_mix(
          rapid_read64(key, p + 80).xor(rapid_secret2),
          rapid_read64(key, p + 88).xor(see2),
        )
        p += 96
        i -= 96
      }
      if i >= 48 {
        seed = rapid_mix(
          rapid_read64(key, p).xor(rapid_secret0),
          rapid_read64(key, p + 8).xor(seed),
        )
        see1 = rapid_mix(
          rapid_read64(key, p + 16).xor(rapid_secret1),
          rapid_read64(key, p + 24).xor(see1),
        )
        see2 = rapid_mix(
          rapid_read64(key, p + 32).xor(rapid_secret2),
          rapid_read64(key, p + 40).xor(see2),
        )
        p += 48
        i -= 48
      }
      seed = seed.xor(see1).xor(see2)
    }
    if i > 16 {
      seed = rapid_mix(
        rapid_read64(key, p).xor(rapid_secret2),
        rapid_read64(key, p + 8).xor(seed).xor(rapid_secret1),
      )
      if i > 32 {
        seed = rapid_mix(
          rapid_read64(key, p + 16).xor(rapid_secret2),
          rapid_read64(key, p + 24).xor(seed),
        )
      }
    }
    a = rapid_read64(key, p + i - 16)
    b = rapid_read64(key, p + i - 8)
  }
  a = a.xor(rapid_secret1)
  b = b.xor(seed)
  let (lo, hi) = rapid_mum(a, b)
  let r = rapid_mix(lo.xor(rapid_secret0).xor(len64), hi.xor(rapid_secret1))
  (r.hi.to_uint64() << 32) | r.lo.to_uint64()
}

///|
/// ninja's `BuildLog::LogEntry::HashCommand`: rapidhash of the command's
/// bytes (`encode_bytes`).
pub fn hash_command(command : String) -> UInt64 {
  rapidhash(encode_bytes(command))
}
