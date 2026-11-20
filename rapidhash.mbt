// rapidhash v1 (https://github.com/Nicoshev/rapidhash, BSD-2-Clause), as
// vendored by ninja v1.13.2 in src/third_party/rapidhash/rapidhash.h with
// RAPIDHASH_FAST and RAPIDHASH_UNROLLED. ninja's build log (format v7)
// stores this hash of each command, so moonja must match it bit for bit.

///|
let rapid_seed : UInt64 = 0xbdd89aa982704029

///|
let rapid_secret0 : UInt64 = 0x2d358dccaa6c78a5

///|
let rapid_secret1 : UInt64 = 0x8bb84b93962eacc9

///|
let rapid_secret2 : UInt64 = 0x4b33a62ed433d4a3

///|
/// The full 128-bit product of `a` and `b` as (low, high), computed from
/// 32-bit halves like rapidhash's portable fallback.
fn rapid_mum(a : UInt64, b : UInt64) -> (UInt64, UInt64) {
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
fn rapid_mix(a : UInt64, b : UInt64) -> UInt64 {
  let (lo, hi) = rapid_mum(a, b)
  lo ^ hi
}

///|
/// The little-endian 32-bit word at `i`. Assembled in 32-bit arithmetic:
/// on the JS backend UInt64 is a BigInt, and each BigInt operation costs.
fn rapid_word32(p : Bytes, i : Int32) -> UInt32 {
  p[i].to_uint() |
  (p[i + 1].to_uint() << 8) |
  (p[i + 2].to_uint() << 16) |
  (p[i + 3].to_uint() << 24)
}

///|
fn rapid_read64(p : Bytes, i : Int32) -> UInt64 {
  rapid_word32(p, i).to_uint64() | (rapid_word32(p, i + 4).to_uint64() << 32)
}

///|
fn rapid_read32(p : Bytes, i : Int32) -> UInt64 {
  rapid_word32(p, i).to_uint64()
}

///|
fn rapid_read_small(p : Bytes, k : Int32) -> UInt64 {
  (p[0].to_uint64() << 56) |
  (p[k >> 1].to_uint64() << 32) |
  p[k - 1].to_uint64()
}

///|
/// rapidhash of `key` with ninja's default seed.
pub fn rapidhash(key : Bytes) -> UInt64 {
  let len = key.length()
  let len64 = len.to_uint64()
  let mut seed = rapid_seed
  seed = seed ^ rapid_mix(seed ^ rapid_secret0, rapid_secret1) ^ len64
  let mut a : UInt64 = 0
  let mut b : UInt64 = 0
  if len <= 16 {
    if len >= 4 {
      let last = len - 4
      a = (rapid_read32(key, 0) << 32) | rapid_read32(key, last)
      let delta = (len & 24) >> (len >> 3)
      b = (rapid_read32(key, delta) << 32) | rapid_read32(key, last - delta)
    } else if len > 0 {
      a = rapid_read_small(key, len)
      b = 0
    }
  } else {
    let mut p = 0
    let mut i = len
    if i > 48 {
      let mut see1 = seed
      let mut see2 = seed
      while i >= 96 {
        seed = rapid_mix(
          rapid_read64(key, p) ^ rapid_secret0,
          rapid_read64(key, p + 8) ^ seed,
        )
        see1 = rapid_mix(
          rapid_read64(key, p + 16) ^ rapid_secret1,
          rapid_read64(key, p + 24) ^ see1,
        )
        see2 = rapid_mix(
          rapid_read64(key, p + 32) ^ rapid_secret2,
          rapid_read64(key, p + 40) ^ see2,
        )
        seed = rapid_mix(
          rapid_read64(key, p + 48) ^ rapid_secret0,
          rapid_read64(key, p + 56) ^ seed,
        )
        see1 = rapid_mix(
          rapid_read64(key, p + 64) ^ rapid_secret1,
          rapid_read64(key, p + 72) ^ see1,
        )
        see2 = rapid_mix(
          rapid_read64(key, p + 80) ^ rapid_secret2,
          rapid_read64(key, p + 88) ^ see2,
        )
        p += 96
        i -= 96
      }
      if i >= 48 {
        seed = rapid_mix(
          rapid_read64(key, p) ^ rapid_secret0,
          rapid_read64(key, p + 8) ^ seed,
        )
        see1 = rapid_mix(
          rapid_read64(key, p + 16) ^ rapid_secret1,
          rapid_read64(key, p + 24) ^ see1,
        )
        see2 = rapid_mix(
          rapid_read64(key, p + 32) ^ rapid_secret2,
          rapid_read64(key, p + 40) ^ see2,
        )
        p += 48
        i -= 48
      }
      seed = seed ^ see1 ^ see2
    }
    if i > 16 {
      seed = rapid_mix(
        rapid_read64(key, p) ^ rapid_secret2,
        rapid_read64(key, p + 8) ^ seed ^ rapid_secret1,
      )
      if i > 32 {
        seed = rapid_mix(
          rapid_read64(key, p + 16) ^ rapid_secret2,
          rapid_read64(key, p + 24) ^ seed,
        )
      }
    }
    a = rapid_read64(key, p + i - 16)
    b = rapid_read64(key, p + i - 8)
  }
  a = a ^ rapid_secret1
  b = b ^ seed
  let (lo, hi) = rapid_mum(a, b)
  rapid_mix(lo ^ rapid_secret0 ^ len64, hi ^ rapid_secret1)
}

///|
/// ninja's `BuildLog::LogEntry::HashCommand`: rapidhash of the command's
/// bytes (`encode_bytes`).
pub fn hash_command(command : String) -> UInt64 {
  rapidhash(encode_bytes(command))
}
