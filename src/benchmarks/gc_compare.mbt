// Head-to-head benchmarks: moonbase (fixed-capacity, allocation-free
// paths) vs moonbitlang/core (dynamic, GC-managed) on the SAME
// workloads.
//
// The point is not to declare a winner. The two libraries sell
// different guarantees — core containers grow and dedupe (moonbase
// refuses to), moonbase containers are bounded and allocation-free
// (core's are not). Measuring both on one workload prices those
// guarantees; docs/benchmarks.md carries the interpretation.
//
// Pairings:
//   moonbase RingBuffer    vs core Queue    — bounded FIFO
//   moonbase BumpAllocator vs core Array    — per-frame scratch memory
//   moonbase SparseSet     vs core HashSet  — alive-set membership
//
// Fairness notes:
//   * Both sides run the identical operation sequence per iteration.
//   * Structures are constructed OUTSIDE the timed closures.
//   * core Queue / HashSet start empty and keep their internal buffers
//     across iterations (steady state), exactly like the moonbase
//     counterparts keep their fixed storage.
//   * MoonBit-visible GC pressure is what it is on each backend — that
//     is part of what these benchmarks measure.

test "benchmarks: moonbase vs core (same workloads)" (it : @bench.T) {
  // `it : @bench.T` is injected by `moon bench` (T is an alias of Bench).

  // --- Bounded FIFO: 64 push + 64 pop per iteration ----------------
  let ring = @collections.RingBuffer::with_capacity(128)
  it.bench(
    () => {
      let mut moved = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        if ring.push(_i) {
          moved = moved + 1
        }
      }
      for _i = 0; _i < 64; _i = _i + 1 {
        match ring.pop() {
          None => ()
          Some(_) => moved = moved + 1
        }
      }
      it.keep(moved)
    },
    name="moonbase ring_buffer: 64 push + 64 pop",
    count=3,
  )

  let q = @queue.Queue([])
  it.bench(
    () => {
      let mut moved = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        q.push(_i)
        moved = moved + 1
      }
      for _i = 0; _i < 64; _i = _i + 1 {
        match q.pop() {
          None => ()
          Some(_) => moved = moved + 1
        }
      }
      it.keep(moved)
    },
    name="core queue: 64 push + 64 pop",
    count=3,
  )

  // --- Per-frame scratch: 64 fresh 32 B buffers, then reset ---------
  let bump = @mem.BumpAllocator::new(4096)
  it.bench(
    () => {
      let mut last = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        match bump.alloc(32, 8) {
          None => ()
          Some(off) => last = off
        }
      }
      bump.reset()
      it.keep(last)
    },
    name="moonbase bump: 64x32B frame + reset",
    count=3,
  )

  it.bench(
    () => {
      let mut total = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        // 8 Int elements = 32 B of scratch, heap-allocated each time.
        let arr = Array::make(8, 0)
        total = total + arr.length()
      }
      it.keep(total)
    },
    name="core Array: 64x8-elem fresh arrays",
    count=3,
  )

  // --- Alive-set membership: 256 insert + 256 remove ---------------
  let set = @collections.SparseSet::with_capacity(1024)
  it.bench(
    () => {
      let mut touched = 0
      for _i = 0; _i < 256; _i = _i + 1 {
        if set.insert(_i) {
          touched = touched + 1
        }
        if set.remove(_i) {
          touched = touched + 1
        }
      }
      it.keep(touched)
    },
    name="moonbase sparse_set: 256 insert + 256 remove",
    count=3,
  )

  let hs = @hashset.HashSet([], capacity=1024)
  it.bench(
    () => {
      let mut touched = 0
      for _i = 0; _i < 256; _i = _i + 1 {
        if hs.add_and_check(_i) {
          touched = touched + 1
        }
        if hs.remove_and_check(_i) {
          touched = touched + 1
        }
      }
      it.keep(touched)
    },
    name="core hashset: 256 add + 256 remove",
    count=3,
  )

  println(it.dump_summaries())
}
