// SlabAllocator: an O(1) fixed-size block allocator.
//
// Every block has the same size; the allocator hands out whole blocks as
// byte offsets into its backing buffer. The free list is threaded through
// a parallel `next[]` array (`FixedArray[Int]`), so allocating and
// freeing never writes to payload bytes — cache lines stay owned by the
// application.
//
// Blocks are recycled LIFO: the most recently freed block is handed out
// first, keeping hot blocks cache-resident. A `-2` sentinel marks
// allocated blocks, so double frees abort instead of corrupting the
// free list.
//
// Use it for object pools and per-entity allocation (game servers,
// embedded firmware) where per-frame `new`/GC churn is unacceptable.
//
// Alignment: block offsets are multiples of `block_size`, so any
// alignment that divides `block_size` is honored for free.
pub struct SlabAllocator {
  buf : Bytes
  block_size : Int
  num_blocks : Int
  next : FixedArray[Int]
  mut free_head : Int
  mut used : Int
}

// Creates a pool of `num_blocks` blocks of `block_size` bytes each.
// Aborts on negative block count or non-positive block size.
//
// Memory overhead: `next[]` costs one `Int` (4-8 bytes) per block, in
// addition to the backing buffer.
pub fn SlabAllocator::new(num_blocks : Int, block_size : Int) -> SlabAllocator {
  guard num_blocks >= 0 else { abort("SlabAllocator::new: negative num_blocks") }
  guard block_size >= 1 else { abort("SlabAllocator::new: block_size must be >= 1") }
  let next = FixedArray::make(num_blocks, 0)
  for i = 0; i < num_blocks - 1; i = i + 1 {
    next[i] = i + 1
  }
  if num_blocks > 0 {
    next[num_blocks - 1] = -1
  }
  let free_head = if num_blocks > 0 { 0 } else { -1 }
  {
    buf: Bytes::make(num_blocks * block_size, b'\x00'),
    block_size,
    num_blocks,
    next,
    free_head,
    used: 0,
  }
}

// Size in bytes of every block handed out by this allocator.
pub fn SlabAllocator::block_size(self : SlabAllocator) -> Int {
  self.block_size
}

// Total number of blocks (allocated or free).
pub fn SlabAllocator::num_blocks(self : SlabAllocator) -> Int {
  self.num_blocks
}

// Total bytes of backing storage: `num_blocks * block_size`.
pub fn SlabAllocator::capacity(self : SlabAllocator) -> Int {
  self.buf.length()
}

// Number of blocks currently handed out.
pub fn SlabAllocator::used(self : SlabAllocator) -> Int {
  self.used
}

// Number of blocks currently free.
pub fn SlabAllocator::free_count(self : SlabAllocator) -> Int {
  self.num_blocks - self.used
}

// Hands out one block, or `None` when the pool is exhausted.
//
// Complexity: O(1).
pub fn SlabAllocator::alloc(self : SlabAllocator) -> Int? {
  if self.free_head < 0 {
    return None
  }
  let block = self.free_head
  self.free_head = self.next[block]
  self.next[block] = -2
  self.used = self.used + 1
  Some(block * self.block_size)
}

// Returns the block starting at `offset` to the pool.
// Aborts (contract violation) on a non-block-aligned offset or a double
// free. The block's bytes are not touched.
//
// Complexity: O(1).
pub fn SlabAllocator::free(self : SlabAllocator, offset : Int) -> Unit {
  guard offset >= 0 && offset % self.block_size == 0 else {
    abort("SlabAllocator::free: offset ${offset} is not block-aligned")
  }
  let block = offset / self.block_size
  guard block < self.num_blocks else {
    abort("SlabAllocator::free: offset ${offset} is out of range")
  }
  guard self.next[block] == -2 else {
    abort("SlabAllocator::free: double free of block ${block}")
  }
  self.next[block] = self.free_head
  self.free_head = block
  self.used = self.used - 1
}

// Reclaims every block, restoring the pool to its initial state.
//
// Complexity: O(num_blocks).
pub fn SlabAllocator::reset(self : SlabAllocator) -> Unit {
  for i = 0; i < self.num_blocks - 1; i = i + 1 {
    self.next[i] = i + 1
  }
  if self.num_blocks > 0 {
    self.next[self.num_blocks - 1] = -1
  }
  self.free_head = if self.num_blocks > 0 { 0 } else { -1 }
  self.used = 0
}

// Trait adaptation: a request is satisfiable iff it fits one block and
// its alignment divides `block_size` (block offsets are multiples of
// `block_size`). A zero-size request still consumes a block.
pub impl Allocator for SlabAllocator with fn alloc(
  self : SlabAllocator,
  size : Int,
  align : Int
) -> Int? {
  if size < 0 || size > self.block_size || align < 1 || self.block_size % align != 0 {
    return None
  }
  self.alloc()
}

pub impl Allocator for SlabAllocator with fn free(self : SlabAllocator, offset : Int) -> Unit {
  self.free(offset)
}

pub impl Allocator for SlabAllocator with fn reset(self : SlabAllocator) -> Unit {
  self.reset()
}

test "slab: blocks are handed out in order and recycled LIFO" {
  let pool = SlabAllocator::new(4, 32)
  assert_eq(pool.alloc(), Some(0))
  assert_eq(pool.alloc(), Some(32))
  assert_eq(pool.alloc(), Some(64))
  assert_eq(pool.alloc(), Some(96))
  assert_true(pool.alloc() is None)
  pool.free(64)
  pool.free(32)
  // Most recently freed block is handed out first.
  assert_eq(pool.alloc(), Some(32))
  assert_eq(pool.alloc(), Some(64))
  assert_true(pool.alloc() is None)
}

test "slab: exhaustion and reuse" {
  let pool = SlabAllocator::new(2, 8)
  assert_true(pool.alloc() is Some(_))
  assert_true(pool.alloc() is Some(_))
  assert_true(pool.alloc() is None)
  assert_eq(pool.used(), 2)
  pool.free(8)
  assert_eq(pool.alloc(), Some(8))
  assert_eq(pool.used(), 2)
  assert_eq(pool.free_count(), 0)
}

test "slab: usable through the Allocator trait" {
  let pool = SlabAllocator::new(8, 16)
  assert_eq(alloc_through_trait(pool, 16, 8), Some(0))
  assert_true(alloc_through_trait(pool, 17, 8) is None, msg="oversized request must fail")
  assert_true(alloc_through_trait(pool, 16, 3) is None, msg="unalignable request must fail")
  assert_eq(pool.used(), 0, msg="reset through the trait must work")
}

// Simulates a game server's entity pool: every frame either spawns an
// entity (one slab block = its component storage) or despawns a random
// live one. Invariants: a slot is never handed out twice while live,
// the pool never exceeds its slot count, and reset reclaims everything.
test "slab: entity pool workload recycles slots" {
  let pool = SlabAllocator::new(64, 16)
  let live = FixedArray::make(64, false)
  let seed = Ref(20260924)
  let mut alive = 0
  for frame = 0; frame < 500; frame = frame + 1 {
    if next_rand(seed) % 3 != 0 {
      match pool.alloc() {
        None => break
        Some(off) => {
          let block = off / pool.block_size()
          assert_false(live[block], msg="slot handed out twice while live")
          live[block] = true
          alive = alive + 1
        }
      }
    } else {
      let target = next_rand(seed) % 64
      if live[target] {
        live[target] = false
        alive = alive - 1
        pool.free(target * pool.block_size())
      }
    }
  }
  assert_true(alive <= pool.num_blocks())
  assert_eq(alive, pool.used())
  assert_eq(alive, 64 - pool.free_count())
  pool.reset()
  assert_eq(pool.used(), 0)
  let mut got = 0
  while pool.alloc() is Some(_) {
    got = got + 1
  }
  assert_eq(got, 64)
}
