// BumpAllocator: an O(1) bump-pointer allocator over a fixed buffer.
//
// Individual blocks are never freed; the whole arena resets at once via
// `reset`. Ideal for frame-based allocation: games, compilers, request
// handlers.
//
// Alignment: honored for any positive `align` (not required to be a power
// of two). Alignment is relative to the start of the backing buffer, not
// absolute. Worst-case waste per allocation is `align - 1` bytes.
// The backing buffer is NOT zeroed on allocation.
//
// Payload access: `storage()` returns the backing `FixedArray[Byte]` so
// offsets from `alloc` are directly usable as indexes. Write only inside
// the block you own — a block from `alloc(size, align)` spans
// [offset, offset + size); bytes outside it belong to other blocks or
// to the frontier. `reset` invalidates every offset at once.
pub struct BumpAllocator {
  buf : FixedArray[Byte]
  mut cursor : Int
}

// Creates an allocator with `capacity` bytes of backing storage.
// Aborts on negative capacity.
pub fn BumpAllocator::new(capacity : Int) -> BumpAllocator {
  guard capacity >= 0 else { abort("BumpAllocator::new: negative capacity") }
  { buf: FixedArray::make(capacity, b'\x00'), cursor: 0 }
}

// Total bytes this allocator can ever hand out.
pub fn BumpAllocator::capacity(self : BumpAllocator) -> Int {
  self.buf.length()
}

// The backing storage itself. Index it with the offsets `alloc` returns
// to read or write payload bytes. The array is shared with the
// allocator: `alloc` only moves the frontier, `free` is a no-op and
// `reset` reclaims everything — none of them touch payload bytes.
pub fn BumpAllocator::storage(self : BumpAllocator) -> FixedArray[Byte] {
  self.buf
}

// Current allocation frontier; blocks below it are live until `reset`.
pub fn BumpAllocator::cursor(self : BumpAllocator) -> Int {
  self.cursor
}

// Allocates `size` bytes aligned to `align`.
//
// Complexity: O(1). Returns `None` on invalid arguments, overflow,
// or out-of-memory. A zero-size request succeeds without advancing.
pub fn BumpAllocator::alloc(self : BumpAllocator, size : Int, align : Int) -> Option[Int] {
  if size < 0 || align < 1 {
    return None
  }
  let aligned = align_up(self.cursor, align)
  let end = aligned + size
  if end < aligned || end > self.buf.length() {
    return None
  }
  self.cursor = end
  Some(aligned)
}

// No-op: bump allocators cannot reclaim individual blocks.
// Use `reset` to reclaim everything at once.
pub fn BumpAllocator::free(_self : BumpAllocator, _offset : Int) -> Unit {}

// Reclaims every block, restoring the allocator to its initial state.
//
// Complexity: O(1).
pub fn BumpAllocator::reset(self : BumpAllocator) -> Unit {
  self.cursor = 0
}

pub impl Allocator for BumpAllocator with fn alloc(
  self : BumpAllocator,
  size : Int,
  align : Int
) -> Int? {
  self.alloc(size, align)
}

pub impl Allocator for BumpAllocator with fn free(self : BumpAllocator, offset : Int) -> Unit {
  self.free(offset)
}

pub impl Allocator for BumpAllocator with fn reset(self : BumpAllocator) -> Unit {
  self.reset()
}

// Smallest multiple of `align` that is >= `x`. `align` must be positive.
fn align_up(x : Int, align : Int) -> Int {
  (x + align - 1) / align * align
}

// Exercises trait dispatch: code generic over `Allocator` must work with
// every implementation. `free` is a documented no-op on bump allocators.
fn[A : Allocator] alloc_through_trait(a : A, size : Int, align : Int) -> Option[Int] {
  match a.alloc(size, align) {
    None => None
    Some(off) => {
      a.free(off)
      a.reset()
      Some(off)
    }
  }
}

test "bump: usable through the Allocator trait" {
  let allocator = BumpAllocator::new(64)
  assert_eq(alloc_through_trait(allocator, 16, 8), Some(0))
  assert_eq(allocator.cursor(), 0, msg="reset through the trait must work")
}

test "bump: allocations are aligned and never overlap" {
  let allocator = BumpAllocator::new(4096)
  let seed = Ref(12345)
  let mut max_end = 0
  for _i = 0; _i < 200; _i = _i + 1 {
    let size = 1 + next_rand(seed) % 64
    let align = 1 + next_rand(seed) % 17
    match allocator.alloc(size, align) {
      None => break
      Some(off) => {
        assert_eq(off % align, 0)
        // Bump offsets are monotonic for non-empty blocks,
        // so no block can overlap an earlier one.
        assert_true(off >= max_end, msg="blocks overlap")
        max_end = off + size
        assert_true(max_end <= allocator.capacity(), msg="blocks exceed capacity")
      }
    }
  }
}

test "bump: reset reclaims all space" {
  let allocator = BumpAllocator::new(1024)
  assert_true(allocator.alloc(512, 8) is Some(_))
  assert_true(allocator.alloc(512, 8) is Some(_))
  assert_true(allocator.alloc(1, 1) is None)
  allocator.reset()
  assert_true(allocator.alloc(1024, 8) is Some(_))
  assert_eq(allocator.cursor(), 1024)
}

test "bump: zero-size alloc succeeds without advancing" {
  let allocator = BumpAllocator::new(64)
  assert_eq(allocator.alloc(0, 1), Some(0))
  assert_eq(allocator.cursor(), 0)
}

test "bump: invalid arguments are rejected with None" {
  let allocator = BumpAllocator::new(64)
  assert_true(allocator.alloc(-1, 1) is None)
  assert_true(allocator.alloc(1, 0) is None)
  assert_true(allocator.alloc(1, -8) is None)
}

test "bump: payload bytes are writable through the returned offset" {
  let allocator = BumpAllocator::new(64)
  match allocator.alloc(16, 8) {
    None => abort("unexpected exhaustion")
    Some(off) => {
      let storage = allocator.storage()
      storage[off] = b'A'
      storage[off + 15] = b'Z'
      assert_eq(storage[off], b'A')
      assert_eq(storage[off + 15], b'Z')
      // Bytes outside the block keep their initial zeroing.
      assert_eq(storage[off + 16], b'\x00')
    }
  }
}

test "bump: separate blocks keep separate payload bytes" {
  let allocator = BumpAllocator::new(64)
  let first = match allocator.alloc(8, 8) {
    Some(off) => off
    None => abort("unexpected exhaustion")
  }
  let second = match allocator.alloc(8, 8) {
    Some(off) => off
    None => abort("unexpected exhaustion")
  }
  let storage = allocator.storage()
  storage[first] = b'1'
  storage[second] = b'2'
  assert_eq(storage[first], b'1')
  assert_eq(storage[second], b'2')
  // reset must not clobber payload bytes (documented behavior).
  allocator.reset()
  assert_eq(storage[first], b'1')
  assert_eq(storage[second], b'2')
}

// Deterministic pseudo-random generator for reproducible tests (LCG).
fn next_rand(seed : Ref[Int]) -> Int {
  seed.val = (seed.val * 1103515245 + 12345) & 0x7FFF_FFFF
  seed.val
}
