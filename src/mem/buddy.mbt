// BuddyAllocator: a power-of-two (buddy) block allocator.
//
// malloc-style variable-size allocation with deterministic behavior and
// no hidden bookkeeping writes into payload bytes. The allocator keeps a
// binary tree in which every node records the largest contiguous free
// block inside its subtree (the classic "longest[]" algorithm):
// allocating descends the tree toward the smallest fitting block, and
// freeing re-forms large blocks automatically by coalescing buddies on
// the way up. After freeing all blocks, the whole buffer is available
// again as a single block — no external fragmentation accumulates.
//
// `capacity` and `min_block` must be powers of two. Every block is
// naturally aligned to its own size, so any alignment that divides
// `min_block` is honored for free; coarser alignments are rejected
// with `None`.
//
// Use it where allocation sizes vary at runtime and fragmentation
// matters: embedded runtimes, kernels, long-lived services. Requests
// round up to the next power of two, so internal fragmentation is
// below 2x per block; external fragmentation is bounded because blocks
// only ever split into buddies and always re-coalesce.
//
// Costs: alloc/free are O(log n) in the buffer size. Bookkeeping is one
// `Int` per tree node (2 * leaves entries, 25% overhead at 64-bit Int,
// min_block = 64).
pub struct BuddyAllocator {
  buf : Bytes
  min_block : Int
  leaves : Int
  tree : FixedArray[Int]
  mut allocated : Int
}

// Creates a buddy allocator over `capacity` bytes with `min_block` as
// the smallest block size. Aborts on non-positive values, non-power-
// of-two values, or capacity not a multiple of min_block.
pub fn BuddyAllocator::new(capacity : Int, min_block : Int) -> BuddyAllocator {
  guard capacity >= 1 else { abort("BuddyAllocator::new: capacity must be >= 1") }
  guard min_block >= 1 else { abort("BuddyAllocator::new: min_block must be >= 1") }
  guard is_pow2(capacity) else {
    abort("BuddyAllocator::new: capacity must be a power of two")
  }
  guard is_pow2(min_block) else {
    abort("BuddyAllocator::new: min_block must be a power of two")
  }
  guard capacity % min_block == 0 else {
    abort("BuddyAllocator::new: capacity must be a multiple of min_block")
  }
  let allocator = {
    buf: Bytes::make(capacity, b'\x00'),
    min_block,
    leaves: capacity / min_block,
    tree: FixedArray::make(2 * (capacity / min_block), 0),
    allocated: 0,
  }
  allocator.reset()
  allocator
}

// Total bytes of backing storage (the whole-buffer block size).
pub fn BuddyAllocator::capacity(self : BuddyAllocator) -> Int {
  self.buf.length()
}

// Smallest allocatable block size in bytes.
pub fn BuddyAllocator::min_block(self : BuddyAllocator) -> Int {
  self.min_block
}

// Bytes currently handed out.
pub fn BuddyAllocator::allocated(self : BuddyAllocator) -> Int {
  self.allocated
}

// Size of the largest contiguous free block (0 when the buffer is
// full). Useful as a fragmentation gauge.
pub fn BuddyAllocator::largest_free(self : BuddyAllocator) -> Int {
  self.tree[1]
}

// Allocates a block of at least `size` bytes (rounded up to the next
// power-of-two multiple of `min_block`), aligned to `align`.
//
// Complexity: O(log n). Returns `None` on invalid arguments, an
// alignment `min_block` cannot honor, a size beyond the buffer, or
// fragmentation/exhaustion. A zero-size request allocates one
// `min_block` block.
pub fn BuddyAllocator::alloc(self : BuddyAllocator, size : Int, align : Int) -> Int? {
  if size < 0 || align < 1 {
    return None
  }
  if align > self.min_block || self.min_block % align != 0 {
    return None
  }
  if size > self.capacity() {
    return None
  }
  let mut target = self.min_block
  while target < size {
    target = target * 2
  }
  if self.tree[1] < target {
    return None
  }
  // Descend toward the leftmost subtree that fits `target`. A node's
  // value is the max of its children (or their merge, see below), so a
  // fitting child always exists while the node itself is bigger than
  // the request.
  let mut node = 1
  let mut node_size = self.capacity()
  while node_size > target {
    let left = node * 2
    node = if self.tree[left] >= target { left } else { left + 1 }
    node_size = node_size / 2
  }
  self.tree[node] = 0
  // The offset is the start of node's range: (node - 2^depth) * size,
  // and 2^depth = capacity / node_size.
  let offset = (node - self.capacity() / node_size) * node_size
  // Update ancestors: a parent whose two halves are both fully free
  // merges back into one block; otherwise it keeps the larger child.
  let mut parent = node / 2
  let mut parent_size = node_size * 2
  while parent >= 1 {
    let left = self.tree[parent * 2]
    let right = self.tree[parent * 2 + 1]
    let half = parent_size / 2
    if left == half && right == half {
      self.tree[parent] = parent_size
    } else if left > right {
      self.tree[parent] = left
    } else {
      self.tree[parent] = right
    }
    parent = parent / 2
    parent_size = parent_size * 2
  }
  self.allocated = self.allocated + target
  Some(offset)
}

// Frees the block starting at `offset`. The block size is recovered
// from the tree, so — unlike C's `free` — no size argument is needed.
// Aborts on a non-block-aligned offset or an offset that is not
// currently allocated (double free).
//
// Complexity: O(log n).
pub fn BuddyAllocator::free(self : BuddyAllocator, offset : Int) -> Unit {
  guard offset >= 0 && offset < self.capacity() && offset % self.min_block == 0 else {
    abort("BuddyAllocator::free: offset \{offset} is not block-aligned")
  }
  // Walk up from the leaf: allocated nodes read 0, free subtrees read
  // their full size, so the first 0 on the path is the allocated node.
  let mut node = self.leaves + offset / self.min_block
  let mut node_size = self.min_block
  while node >= 1 && self.tree[node] != 0 {
    node = node / 2
    node_size = node_size * 2
  }
  guard node >= 1 else {
    abort("BuddyAllocator::free: offset \{offset} is not allocated (double free?)")
  }
  self.tree[node] = node_size
  self.allocated = self.allocated - node_size
  // Update ancestors with the same merge rule as alloc: two fully free
  // halves coalesce back into their parent block.
  let mut parent = node / 2
  let mut parent_size = node_size * 2
  while parent >= 1 {
    let left = self.tree[parent * 2]
    let right = self.tree[parent * 2 + 1]
    let half = parent_size / 2
    if left == half && right == half {
      self.tree[parent] = parent_size
    } else if left > right {
      self.tree[parent] = left
    } else {
      self.tree[parent] = right
    }
    parent = parent / 2
    parent_size = parent_size * 2
  }
}

// Reclaims every block, restoring the whole buffer as one free block.
//
// Complexity: O(n) in the number of leaves.
pub fn BuddyAllocator::reset(self : BuddyAllocator) -> Unit {
  let bound = self.leaves * 2
  for i = self.leaves; i < bound; i = i + 1 {
    self.tree[i] = self.min_block
  }
  for i = self.leaves - 1; i >= 1; i = i - 1 {
    self.tree[i] = self.tree[2 * i] + self.tree[2 * i + 1]
  }
  self.allocated = 0
}

pub impl Allocator for BuddyAllocator with fn alloc(
  self : BuddyAllocator,
  size : Int,
  align : Int
) -> Int? {
  self.alloc(size, align)
}

pub impl Allocator for BuddyAllocator with fn free(self : BuddyAllocator, offset : Int) -> Unit {
  self.free(offset)
}

pub impl Allocator for BuddyAllocator with fn reset(self : BuddyAllocator) -> Unit {
  self.reset()
}

fn is_pow2(x : Int) -> Bool {
  x > 0 && (x & (x - 1)) == 0
}

test "buddy: sizes, alignment and exhaustion" {
  let allocator = BuddyAllocator::new(1024, 64)
  for i = 0; i < 16; i = i + 1 {
    match allocator.alloc(1, 1) {
      Some(off) => assert_eq(off % 64, 0)
      None => abort("unexpected exhaustion")
    }
  }
  assert_true(allocator.alloc(1, 1) is None)
  assert_eq(allocator.allocated(), 1024)
  assert_true(allocator.alloc(2048, 1) is None, msg="block larger than the buffer")
}

test "buddy: buddies coalesce after free" {
  let allocator = BuddyAllocator::new(4096, 64)
  assert_eq(allocator.alloc(64, 8), Some(0))
  assert_eq(allocator.alloc(64, 8), Some(64))
  // The two 64 B leaves pin their 128 B parent; the largest free block
  // is now the untouched 2048 B half.
  assert_eq(allocator.largest_free(), 2048)
  allocator.free(64)
  allocator.free(0)
  // Both buddies are free again, so the whole buffer re-forms.
  assert_eq(allocator.largest_free(), 4096)
  assert_eq(allocator.alloc(4096, 8), Some(0))
  assert_eq(allocator.allocated(), 4096)
  allocator.free(0)
  assert_eq(allocator.allocated(), 0)
}

// A randomized malloc-style workload: powers-of-two requests in
// [64, 512] bytes interleaved with random frees of live blocks. The
// mirror array tracks which leaf belongs to which live block, so any
// overlap between live allocations is caught. After freeing everything,
// the tree must have coalesced back to a single full-buffer block.
test "buddy: malloc-style workload keeps blocks disjoint and coalesces fully" {
  let allocator = BuddyAllocator::new(4096, 64)
  let seed = Ref(777)
  let leaf_mark = FixedArray::make(64, 0)
  let offsets = FixedArray::make(64, 0)
  let sizes = FixedArray::make(64, 0)
  let mut live_count = 0
  for step = 0; step < 400; step = step + 1 {
    let r = next_rand(seed)
    if r % 4 != 0 {
      let size = 64 << (next_rand(seed) % 4)
      match allocator.alloc(size, 8) {
        None => continue
        Some(off) => {
          let first = off / 64
          assert_eq(leaf_mark[first], 0, msg="new block overlaps a live one")
          leaf_mark[first] = size
          for i = 1; i < size / 64; i = i + 1 {
            leaf_mark[first + i] = -1
          }
          offsets[live_count] = off
          sizes[live_count] = size
          live_count = live_count + 1
          assert_true(live_count <= 64)
        }
      }
    } else if live_count > 0 {
      let pick = next_rand(seed) % live_count
      let off = offsets[pick]
      let size = sizes[pick]
      let first = off / 64
      assert_true(leaf_mark[first] > 0, msg="freeing a block we did not allocate")
      leaf_mark[first] = 0
      for i = 1; i < size / 64; i = i + 1 {
        leaf_mark[first + i] = 0
      }
      allocator.free(off)
      live_count = live_count - 1
      offsets[pick] = offsets[live_count]
      sizes[pick] = sizes[live_count]
    }
  }
  for i = 0; i < live_count; i = i + 1 {
    allocator.free(offsets[i])
  }
  assert_eq(allocator.largest_free(), 4096)
  assert_eq(allocator.allocated(), 0)
  assert_eq(allocator.alloc(4096, 8), Some(0))
}

test "buddy: usable through the Allocator trait" {
  let allocator = BuddyAllocator::new(4096, 64)
  assert_eq(alloc_through_trait(allocator, 512, 8), Some(0))
  assert_true(
    alloc_through_trait(allocator, 512, 128) is None,
    msg="align beyond min_block must fail",
  )
  assert_true(
    alloc_through_trait(allocator, 512, 3) is None,
    msg="align not dividing min_block must fail",
  )
  assert_eq(allocator.allocated(), 0, msg="reset through the trait must work")
}

test "buddy: invalid requests are rejected with None" {
  let allocator = BuddyAllocator::new(1024, 64)
  assert_true(allocator.alloc(-1, 1) is None)
  assert_true(allocator.alloc(1, 0) is None)
  assert_true(allocator.alloc(1, 96) is None, msg="align must not exceed min_block")
  assert_true(allocator.alloc(1, 48) is None, msg="align must divide min_block")
  assert_true(allocator.alloc(1025, 1) is None, msg="size must not exceed capacity")
}
