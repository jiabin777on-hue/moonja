// The UInt64 implementation rapidhash.mbt had before it moved to 32-bit
// halves, kept as a reference for the test below.

///|
let ref_rapid_seed : UInt64 = 0xbdd89aa982704029

///|
let ref_rapid_secret0 : UInt64 = 0x2d358dccaa6c78a5

///|
let ref_rapid_secret1 : UInt64 = 0x8bb84b93962eacc9

///|
let ref_rapid_secret2 : UInt64 = 0x4b33a62ed433d4a3

///|
/// The full 128-bit product of `a` and `b` as (low, high), computed from
/// 32-bit halves like ref_rapidhash's portable fallback.
fn ref_rapid_mum(a : UInt64, b : UInt64) -> (UInt64, UInt64) {
  let mask : UInt64 = 0xffffffff
  let ha = a >> 32
  let hb = b >> 32
  let la = a & mask
  let lb = b & mask
  let rh = ha * hb
  let rm0 = ha * lb
  let rm1 = hb * la
  let rl = la * lb
  let t = rl + (rm0 << 32)
  let mut c : UInt64 = if t < rl { 1 } else { 0 }
  let lo = t + (rm1 << 32)
  c += if lo < t { 1 } else { 0 }
  let hi = rh + (rm0 >> 32) + (rm1 >> 32) + c
  (lo, hi)
}

///|
fn ref_rapid_mix(a : UInt64, b : UInt64) -> UInt64 {
  let (lo, hi) = ref_rapid_mum(a, b)
  lo ^ hi
}

///|
/// The little-endian 32-bit word at `i`. Assembled in 32-bit arithmetic:
/// on the JS backend UInt64 is a BigInt, and each BigInt operation costs.
fn ref_rapid_word32(p : Bytes, i : Int32) -> UInt32 {
  p[i].to_uint() |
  (p[i + 1].to_uint() << 8) |
  (p[i + 2].to_uint() << 16) |
  (p[i + 3].to_uint() << 24)
}

///|
fn ref_rapid_read64(p : Bytes, i : Int32) -> UInt64 {
  ref_rapid_word32(p, i).to_uint64() |
  (ref_rapid_word32(p, i + 4).to_uint64() << 32)
}

///|
fn ref_rapid_read32(p : Bytes, i : Int32) -> UInt64 {
  ref_rapid_word32(p, i).to_uint64()
}

///|
fn ref_rapid_read_small(p : Bytes, k : Int32) -> UInt64 {
  (p[0].to_uint64() << 56) |
  (p[k >> 1].to_uint64() << 32) |
  p[k - 1].to_uint64()
}

///|
/// ref_rapidhash of `key` with ninja's default seed.
fn ref_rapidhash(key : Bytes) -> UInt64 {
  let len = key.length()
  let len64 = len.to_uint64()
  let mut seed = ref_rapid_seed
  seed = seed ^
    ref_rapid_mix(seed ^ ref_rapid_secret0, ref_rapid_secret1) ^
    len64
  let mut a : UInt64 = 0
  let mut b : UInt64 = 0
  if len <= 16 {
    if len >= 4 {
      let last = len - 4
      a = (ref_rapid_read32(key, 0) << 32) | ref_rapid_read32(key, last)
      let delta = (len & 24) >> (len >> 3)
      b = (ref_rapid_read32(key, delta) << 32) |
        ref_rapid_read32(key, last - delta)
    } else if len > 0 {
      a = ref_rapid_read_small(key, len)
      b = 0
    }
  } else {
    let mut p = 0
    let mut i = len
    if i > 48 {
      let mut see1 = seed
      let mut see2 = seed
      while i >= 96 {
        seed = ref_rapid_mix(
          ref_rapid_read64(key, p) ^ ref_rapid_secret0,
          ref_rapid_read64(key, p + 8) ^ seed,
        )
        see1 = ref_rapid_mix(
          ref_rapid_read64(key, p + 16) ^ ref_rapid_secret1,
          ref_rapid_read64(key, p + 24) ^ see1,
        )
        see2 = ref_rapid_mix(
          ref_rapid_read64(key, p + 32) ^ ref_rapid_secret2,
          ref_rapid_read64(key, p + 40) ^ see2,
        )
        seed = ref_rapid_mix(
          ref_rapid_read64(key, p + 48) ^ ref_rapid_secret0,
          ref_rapid_read64(key, p + 56) ^ seed,
        )
        see1 = ref_rapid_mix(
          ref_rapid_read64(key, p + 64) ^ ref_rapid_secret1,
          ref_rapid_read64(key, p + 72) ^ see1,
        )
        see2 = ref_rapid_mix(
          ref_rapid_read64(key, p + 80) ^ ref_rapid_secret2,
          ref_rapid_read64(key, p + 88) ^ see2,
        )
        p += 96
        i -= 96
      }
      if i >= 48 {
        seed = ref_rapid_mix(
          ref_rapid_read64(key, p) ^ ref_rapid_secret0,
          ref_rapid_read64(key, p + 8) ^ seed,
        )
        see1 = ref_rapid_mix(
          ref_rapid_read64(key, p + 16) ^ ref_rapid_secret1,
          ref_rapid_read64(key, p + 24) ^ see1,
        )
        see2 = ref_rapid_mix(
          ref_rapid_read64(key, p + 32) ^ ref_rapid_secret2,
          ref_rapid_read64(key, p + 40) ^ see2,
        )
        p += 48
        i -= 48
      }
      seed = seed ^ see1 ^ see2
    }
    if i > 16 {
      seed = ref_rapid_mix(
        ref_rapid_read64(key, p) ^ ref_rapid_secret2,
        ref_rapid_read64(key, p + 8) ^ seed ^ ref_rapid_secret1,
      )
      if i > 32 {
        seed = ref_rapid_mix(
          ref_rapid_read64(key, p + 16) ^ ref_rapid_secret2,
          ref_rapid_read64(key, p + 24) ^ seed,
        )
      }
    }
    a = ref_rapid_read64(key, p + i - 16)
    b = ref_rapid_read64(key, p + i - 8)
  }
  a = a ^ ref_rapid_secret1
  b = b ^ seed
  let (lo, hi) = ref_rapid_mum(a, b)
  ref_rapid_mix(lo ^ ref_rapid_secret0 ^ len64, hi ^ ref_rapid_secret1)
}

///|
test "rapidhash in 32-bit halves agrees with the UInt64 version" {
  // Every length up to 300 (all branches of the algorithm), with bytes
  // from a fixed linear congruential sequence, several keys per length.
  let mut seed = 2463534242U
  let next = fn() -> Byte {
    seed = seed * 1664525U + 1013904223U
    (seed >> 24).to_byte()
  }
  for len in 0..<300 {
    for _ in 0..<4 {
      let key = Bytes::makei(len, fn(_) { next() })
      let got = rapidhash(key)
      let want = ref_rapidhash(key)
      if got != want {
        fail("length \{len}: \{got} vs \{want}")
      }
    }
  }
  // All bytes 0xff, where every carry propagates.
  for len in 0..<300 {
    let key = Bytes::make(len, b'\xFF')
    assert_eq(rapidhash(key), ref_rapidhash(key))
  }
}
