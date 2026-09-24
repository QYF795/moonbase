// Arena: an append-only typed arena over a `FixedArray`.
//
// The typed layer on top of the raw allocators: `alloc` stores a value
// and returns an integer handle (its index) instead of a reference, so
// handles can never dangle into freed memory — after `reset`, every old
// handle simply aborts on `get` (contract violation) instead of reading
// garbage. Per-slot freeing is intentionally unsupported: arenas are
// reclaimed wholesale, like bump allocation, which matches the lifetime
// of frame-scoped and phase-scoped data exactly.
//
// `reset` clears every slot (O(n)), which matters on GC backends: stale
// references are dropped so objects die at reset, not at their next
// overwrite.
//
// Use it for per-frame transient objects (draw lists, command buffers),
// compiler phases (ASTs, intermediate forms) and request-scoped data —
// anywhere a bump lifetime plus typed access beats raw offsets.
pub struct Arena[T] {
  slots : FixedArray[Option[T]]
  mut count : Int
}

// Creates an empty arena that holds at most `capacity` values.
// Aborts on negative capacity.
pub fn[T] Arena::with_capacity(capacity : Int) -> Arena[T] {
  guard capacity >= 0 else { abort("Arena::with_capacity: negative capacity") }
  { slots: FixedArray::make(capacity, None), count: 0 }
}

pub fn[T] Arena::capacity(self : Arena[T]) -> Int {
  self.slots.length()
}

// Number of values currently stored (the live handle range).
pub fn[T] Arena::len(self : Arena[T]) -> Int {
  self.count
}

pub fn[T] Arena::is_empty(self : Arena[T]) -> Bool {
  self.count == 0
}

pub fn[T] Arena::is_full(self : Arena[T]) -> Bool {
  self.count == self.slots.length()
}

// Stores `value` and returns its handle (index), or `None` when full.
// The arena itself performs no GC allocation during `alloc`.
//
// Complexity: O(1).
pub fn[T] Arena::alloc(self : Arena[T], value : T) -> Int? {
  if self.is_full() {
    return None
  }
  let handle = self.count
  self.slots[handle] = Some(value)
  self.count = self.count + 1
  Some(handle)
}

// Returns the value stored at `handle`. Aborts when the handle is out
// of the live range [0, len) — including every handle from before a
// `reset`, so stale handles fail loudly instead of dangling.
//
// Complexity: O(1).
pub fn[T] Arena::get(self : Arena[T], handle : Int) -> T {
  if handle < 0 || handle >= self.count {
    abort("Arena: handle \{handle} out of live range [0, \{self.count})")
  }
  match self.slots[handle] {
    None => abort("Arena: handle \{handle} slot is empty (internal count mismatch)")
    Some(value) => value
  }
}

// Reclaims every slot at once. Old handles become invalid (see `get`).
//
// Complexity: O(len). Slots are cleared so references die at reset —
// on GC backends this releases memory immediately instead of at the
// next overwrite.
pub fn[T] Arena::reset(self : Arena[T]) -> Unit {
  for i = 0; i < self.count; i = i + 1 {
    self.slots[i] = None
  }
  self.count = 0
}

test "arena: alloc hands out sequential handles and get reads them back" {
  let arena = Arena::with_capacity(4)
  assert_eq(arena.alloc("a"), Some(0))
  assert_eq(arena.alloc("b"), Some(1))
  assert_eq(arena.alloc("c"), Some(2))
  assert_eq(arena.len(), 3)
  assert_eq(arena.get(0), "a")
  assert_eq(arena.get(1), "b")
  assert_eq(arena.get(2), "c")
}

test "arena: exhaustion reports None without dropping anything" {
  let arena = Arena::with_capacity(2)
  assert_true(arena.alloc(1) is Some(_))
  assert_true(arena.alloc(2) is Some(_))
  assert_true(arena.alloc(3) is None)
  assert_true(arena.is_full())
  assert_eq(arena.len(), 2)
  assert_eq(arena.get(0), 1)
  assert_eq(arena.get(1), 2)
}

test "arena: reset reclaims every slot for reuse" {
  let arena = Arena::with_capacity(2)
  assert_true(arena.alloc(10) is Some(_))
  assert_true(arena.alloc(20) is Some(_))
  arena.reset()
  assert_eq(arena.len(), 0)
  assert_true(arena.is_empty())
  // Handles restart from zero; old handles would now abort.
  assert_eq(arena.alloc(30), Some(0))
  assert_eq(arena.alloc(40), Some(1))
  assert_eq(arena.get(0), 30)
  assert_eq(arena.get(1), 40)
}

// A game frame allocates its transient objects (draw commands) into
// the frame arena and resets at the frame's end. Across 100 frames the
// same slot range must be reused exactly, and every handle must stay
// valid for the whole frame it was issued in.
test "arena: per-frame transient objects reuse the same slots" {
  let arena = Arena::with_capacity(64)
  for frame = 0; frame < 100; frame = frame + 1 {
    let mut draws = 0
    while true {
      match arena.alloc("draw_\{frame}_\{draws}") {
        None => break
        Some(_) => draws = draws + 1
      }
    }
    assert_eq(draws, 64)
    assert_eq(arena.len(), 64)
    assert_eq(arena.get(0), "draw_\{frame}_0")
    assert_eq(arena.get(63), "draw_\{frame}_63")
    arena.reset()
  }
}

test "arena: zero capacity is a valid empty arena" {
  let arena = Arena::with_capacity(0)
  assert_true(arena.is_empty())
  assert_true(arena.is_full())
  assert_true(arena.alloc(1) is None)
  arena.reset()
  assert_eq(arena.len(), 0)
}
