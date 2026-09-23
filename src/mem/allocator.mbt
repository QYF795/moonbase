// Low-level block allocators over a fixed backing buffer.
//
// Design: allocators return byte offsets (plain `Int`) into their buffer
// instead of pointers. Allocation therefore performs no GC allocation,
// making the allocators usable in hot paths and no-allocation contexts.
//
// Contract conventions (see docs/design.md):
// - `Option`/`Bool` return value: resource exhaustion (OOM, queue full)
// - `abort`: contract violation (out-of-bounds index, misuse)
//
// `free` may be a no-op: implementations that cannot reclaim individual
// blocks (e.g. bump allocators) ignore it and reclaim via `reset`.
pub trait Allocator {
  // Allocates a block of `size` bytes aligned to `align`, returning the
  // offset of the block, or `None` if the allocator cannot satisfy it.
  fn alloc(Self, size : Int, align : Int) -> Int?
  // Frees the block starting at `offset` previously returned by `alloc`.
  // May be a no-op; see the trait docs.
  fn free(Self, offset : Int) -> Unit
  // Reclaims all blocks; every previously returned offset becomes invalid.
  fn reset(Self) -> Unit
}
