// Ported from ninja v1.13.2 src/jobserver_test.cc (Apache-2.0, see
// NOTICE). Test names follow the original; the FIFO of PosixFifoClient is
// an in-memory pool here (the host's FIFO is tested by misc/jobserver_test.py
// in CI).

///|
fn parse_flags(makeflags : String) -> @moonja.JobserverConfig raise {
  @moonja.parse_makeflags(makeflags)
}

///|
fn makeflags_error(makeflags : String) -> String {
  ignore(@moonja.parse_makeflags(makeflags)) catch {
    error => return error.message()
  }
  "no error"
}

///|
fn native_error(makeflags : String, platform : @moonja.Platform) -> String {
  ignore(@moonja.parse_native_makeflags(makeflags, platform~)) catch {
    error => return error.message()
  }
  "no error"
}

///|
test "Jobserver.SlotTest" {
  let slot : @moonja.JobSlot = NoSlot
  assert_false(slot.is_valid())
  let slot0 : @moonja.JobSlot = Implicit
  assert_true(slot0.is_valid())
  let slot1 : @moonja.JobSlot = Explicit(b'\x0a')
  assert_true(slot1.is_valid())
  assert_true(slot1 is Explicit(b'\x0a'))
}

///|
test "Jobserver.ParseMakeFlagsValue" {
  // An empty string, or only whitespace.
  assert_eq(parse_flags("").mode, NoMode)
  assert_eq(parse_flags("  \t").mode, NoMode)
  // An `n` in the first word reports no mode.
  assert_eq(parse_flags("kns --jobserver-auth=fifo:foo").mode, NoMode)
  // --jobserver-auth=fifo:<path> works.
  assert_eq(parse_flags("--jobserver-auth=fifo:foo"), {
    mode: PosixFifo,
    path: "foo",
  })
  // An initial " -j" or " -j<count>" works.
  assert_eq(parse_flags(" -j --jobserver-auth=fifo:foo"), {
    mode: PosixFifo,
    path: "foo",
  })
  assert_eq(parse_flags(" -j10 --jobserver-auth=fifo:foo"), {
    mode: PosixFifo,
    path: "foo",
  })
  // An `n` in a first word after a dash is not make's dry-run flag.
  assert_eq(parse_flags("-one-flag --jobserver-auth=fifo:foo").mode, PosixFifo)
  assert_eq(parse_flags("--jobserver-auth=semaphore_name"), {
    mode: Win32Semaphore,
    path: "semaphore_name",
  })
  assert_eq(parse_flags("--jobserver-auth=10,42").mode, Pipe)
  assert_eq(parse_flags("--jobserver-auth=-1,42").mode, NoMode)
  assert_eq(parse_flags("--jobserver-auth=10,-42").mode, NoMode)
  // The last one wins.
  assert_eq(
    parse_flags(
      "--jobserver-auth=10,42 --jobserver-fds=12,44 --jobserver-auth=fifo:/tmp/fifo",
    ),
    { mode: PosixFifo, path: "/tmp/fifo", },
  )
  inspect(
    makeflags_error("--jobserver-fds=10,"),
    content="Invalid file descriptor pair [10,]",
  )
}

///|
test "Jobserver.ParseNativeMakeFlagsValue" {
  // --jobserver-auth=R,W is not supported.
  inspect(
    native_error("--jobserver-auth=3,4", Posix),
    content="Pipe-based protocol is not supported!",
  )
  // Windows: semaphores work, FIFOs do not.
  inspect(
    native_error("--jobserver-auth=semaphore_name", Windows),
    content="no error",
  )
  inspect(
    native_error("--jobserver-auth=fifo:foo", Windows),
    content="FIFO mode is not supported on Windows!",
  )
  // POSIX: FIFOs work, semaphores do not.
  inspect(
    native_error("--jobserver-auth=semaphore_name", Posix),
    content="Semaphore mode is not supported on Posix!",
  )
  assert_eq(
    @moonja.parse_native_makeflags("--jobserver-auth=fifo:foo", platform=Posix),
    { mode: PosixFifo, path: "foo", },
  )
}

///|
/// A FIFO's contents.
struct MemoryPool {
  bytes : Array[Byte]
  written : Array[Byte]
}

///|
impl @moonja.JobserverPool for MemoryPool with fn try_read(self) {
  if self.bytes.is_empty() {
    None
  } else {
    Some(self.bytes.remove(0))
  }
}

///|
impl @moonja.JobserverPool for MemoryPool with fn write(self, byte) {
  self.written.push(byte)
  self.bytes.push(byte)
}

///|
fn create_error(config : @moonja.JobserverConfig) -> String {
  ignore(
    @moonja.create_jobserver_client(config, open_fifo=fn(_) {
      Err("Not a fifo path: not_a_fifo")
    }),
  ) catch {
    error => return error.message()
  }
  "no error"
}

///|
test "Jobserver.NullJobserver" {
  inspect(
    create_error({ mode: NoMode, path: "", }),
    content="Unsupported jobserver mode",
  )
}

///|
test "Jobserver.PosixFifoClient" {
  let pool = MemoryPool::{ bytes: [b'0', b'1', b'2', b'3', b'4'], written: [], }
  let client = @moonja.create_jobserver_client(
    { mode: PosixFifo, path: "fifo", },
    open_fifo=fn(_) { Ok(pool) },
  )
  // The first slot is always implicit.
  let slots = [client.try_acquire()]
  assert_eq(slots[0], Implicit)
  // Then the bytes of the pool, in order.
  for n in 0..<5 {
    let slot = client.try_acquire()
    assert_eq(slot, Explicit((b'0'.to_int() + n).to_byte()))
    slots.push(slot)
  }
  // The pool is empty now.
  assert_eq(client.try_acquire(), NoSlot)
  // Released slots go back as they came: the implicit one without
  // touching the pool.
  for slot in slots {
    client.release(slot)
  }
  inspect(pool.written.length(), content="5")
  assert_eq(client.try_acquire(), Implicit)
}

///|
test "Jobserver.PosixFifoClientWithWrongPath" {
  inspect(
    create_error({ mode: PosixFifo, path: "not_a_fifo", }),
    content="Not a fifo path: not_a_fifo",
  )
  inspect(
    create_error({ mode: PosixFifo, path: "", }),
    content="Empty fifo path",
  )
}

///|
test "Plan takes jobserver slots for its edges" {
  let f = plan_fixture(
    (
      #|build out1: cat in
      #|build out2: cat in
      #|build out3: cat in
      #|build all: phony out1 out2 out3
      #|
    ),
  )
  f.dirty(["out1", "out2", "out3", "all"])
  let pool = MemoryPool::{ bytes: [b'+'], written: [], }
  f.plan.set_jobserver_client(@moonja.JobserverClient::new(pool))
  f.prepare_for_target("all")
  // The implicit slot and the pool's one token: two edges, then none.
  let e1 = f.work()
  let e2 = f.work()
  assert_true(f.plan.find_work() is None)
  // Finishing an edge frees its slot for the next.
  f.finish(e1)
  let e3 = f.work()
  assert_true(f.plan.find_work() is None)
  f.finish(e2)
  f.finish(e3)
  // The phony edge, then nothing left.
  let phony = f.work()
  f.finish(phony)
  assert_false(f.plan.more_to_do())
  // The implicit slot is handed out first, so e3 and the phony edge ran in
  // it again: only e2's token went back to the pool.
  inspect(pool.written.length(), content="1")
  inspect(pool.bytes.length(), content="1")
}
