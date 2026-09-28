// Benchmark suite: every public module under a realistic workload.
//
// The `(it : @bench.T)` parameter marks this as a bench test: it runs
// under `moon bench` (CI runs it natively in release mode) and is
// skipped by plain `moon test`. The numbers are not absolute
// performance claims — they anchor the cross-module comparisons in
// docs/benchmarks.md to measurements on one machine, and they turn
// regressions into CI failures by their very presence.
//
// Each workload mirrors the scenario demo of its module: the same access
// pattern an application would issue. `count=3` keeps a full run to a
// few seconds per target so the suite stays CI-friendly.
//
// Structures are constructed OUTSIDE the timed closures: construction
// costs (O(n) tree setup for buddy, O(n) free-list setup for slab) are
// one-time and not what these benchmarks measure.

test "benchmarks: allocators and containers" (it : @bench.T) {
  // `it : @bench.T` is injected by `moon bench` (T is an alias of Bench).

  // Per-frame scratch allocation: 64 x 32 B per frame, then reset.
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
    name="bump: 64x32B frame + reset",
    count=3,
  )

  // Entity-pool churn: hand out a block, return it immediately.
  let slab = @mem.SlabAllocator::new(256, 16)
  it.bench(
    () => {
      let mut handed = 0
      for _i = 0; _i < 128; _i = _i + 1 {
        match slab.alloc() {
          None => ()
          Some(off) => {
            slab.free(off)
            handed = handed + 1
          }
        }
      }
      it.keep(handed)
    },
    name="slab: alloc+free 16B blocks",
    count=3,
  )

  // malloc-style small blocks: the common size class.
  let buddy = @mem.BuddyAllocator::new(65536, 64)
  it.bench(
    () => {
      let mut handed = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        match buddy.alloc(64, 8) {
          None => ()
          Some(off) => {
            buddy.free(off)
            handed = handed + 1
          }
        }
      }
      it.keep(handed)
    },
    name="buddy: alloc+free 64B",
    count=3,
  )

  // malloc-style large blocks: deeper tree descent and merge.
  let buddy_large = @mem.BuddyAllocator::new(65536, 64)
  it.bench(
    () => {
      let mut handed = 0
      for _i = 0; _i < 32; _i = _i + 1 {
        match buddy_large.alloc(512, 8) {
          None => ()
          Some(off) => {
            buddy_large.free(off)
            handed = handed + 1
          }
        }
      }
      it.keep(handed)
    },
    name="buddy: alloc+free 512B",
    count=3,
  )

  // Typed arena: frame transient objects stored by value, reset at end.
  let arena = @mem.Arena::with_capacity(64)
  it.bench(
    () => {
      let mut handled = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        match arena.alloc(_i) {
          None => ()
          Some(_) => handled = handled + 1
        }
      }
      arena.reset()
      it.keep(handled)
    },
    name="arena: 64 values + reset",
    count=3,
  )

  // Bounded FIFO: half fill then half drain, staying off both extremes.
  let ring = @collections.RingBuffer::with_capacity(256)
  it.bench(
    () => {
      let mut moved = 0
      for _i = 0; _i < 128; _i = _i + 1 {
        if ring.push(_i) {
          moved = moved + 1
        }
      }
      for _i = 0; _i < 128; _i = _i + 1 {
        match ring.pop() {
          None => ()
          Some(_) => moved = moved + 1
        }
      }
      it.keep(moved)
    },
    name="ring_buffer: 128 push + 128 pop",
    count=3,
  )

  // Work-stealing pattern: owner pushes front, thief pops back.
  let deque = @collections.FixedDeque::with_capacity(128)
  it.bench(
    () => {
      let mut moved = 0
      for _i = 0; _i < 64; _i = _i + 1 {
        if deque.push_front(_i) {
          moved = moved + 1
        }
      }
      for _i = 0; _i < 64; _i = _i + 1 {
        match deque.pop_back() {
          None => ()
          Some(_) => moved = moved + 1
        }
      }
      it.keep(moved)
    },
    name="fixed_deque: 64 push_front + 64 pop_back",
    count=3,
  )

  // ECS alive-set churn over a 1024-entity universe.
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
    name="sparse_set: 256 insert + 256 remove",
    count=3,
  )

  // Dirty-flag bookkeeping: set, read, and count over 4096 bits.
  let bits = @collections.BitVec::with_capacity(4096)
  it.bench(
    () => {
      let mut total = 0
      for _i = 0; _i < 4096; _i = _i + 1 {
        bits.set(_i, _i % 3 == 0)
      }
      for _i = 0; _i < 4096; _i = _i + 1 {
        if bits.get(_i) {
          total = total + 1
        }
      }
      total = total + bits.popcnt()
      it.keep(total)
    },
    name="bit_vec: set+scan 4096 bits + popcnt",
    count=3,
  )

  println(it.dump_summaries())
}
