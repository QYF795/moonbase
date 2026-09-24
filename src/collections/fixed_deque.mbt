// FixedDeque: a fixed-capacity double-ended queue over a `FixedArray`.
//
// This is the data structure under work-stealing schedulers (Go's
// runtime, tokio's scheduler): one owner thread pushes and pops at the
// FRONT (LIFO — freshly spawned tasks are cache-hot), while idle
// threads steal from the BACK (FIFO — the oldest, coldest tasks,
// keeping contention off the owner's end).
//
// All operations are O(1). Pushes return false when full and never
// overwrite, so the structure itself needs no lock for single-owner /
// multi-thief usage (cross-thread memory ordering is out of scope —
// see docs/design.md).
//
// Compared to RingBuffer (strict FIFO, SPSC-friendly), FixedDeque
// trades a second pointer for double-ended access.
pub struct FixedDeque[T] {
  buf : FixedArray[Option[T]]
  mut head : Int
  mut count : Int
}

// Creates an empty deque that holds at most `capacity` elements.
// Aborts on negative capacity.
pub fn[T] FixedDeque::with_capacity(capacity : Int) -> FixedDeque[T] {
  guard capacity >= 0 else { abort("FixedDeque::with_capacity: negative capacity") }
  { buf: FixedArray::make(capacity, None), head: 0, count: 0 }
}

pub fn[T] FixedDeque::capacity(self : FixedDeque[T]) -> Int {
  self.buf.length()
}

pub fn[T] FixedDeque::len(self : FixedDeque[T]) -> Int {
  self.count
}

pub fn[T] FixedDeque::is_empty(self : FixedDeque[T]) -> Bool {
  self.count == 0
}

pub fn[T] FixedDeque::is_full(self : FixedDeque[T]) -> Bool {
  self.count == self.buf.length()
}

// Pushes `value` at the front (the owner's end). Returns false
// (dropping nothing) when full.
//
// Complexity: O(1).
pub fn[T] FixedDeque::push_front(self : FixedDeque[T], value : T) -> Bool {
  if self.is_full() {
    return false
  }
  self.head = (self.head - 1 + self.buf.length()) % self.buf.length()
  self.buf[self.head] = Some(value)
  self.count = self.count + 1
  true
}

// Pushes `value` at the back (the thieves' end). Returns false
// (dropping nothing) when full.
//
// Complexity: O(1).
pub fn[T] FixedDeque::push_back(self : FixedDeque[T], value : T) -> Bool {
  if self.is_full() {
    return false
  }
  let index = (self.head + self.count) % self.buf.length()
  self.buf[index] = Some(value)
  self.count = self.count + 1
  true
}

// Removes and returns the front element, or None when empty.
//
// Complexity: O(1).
pub fn[T] FixedDeque::pop_front(self : FixedDeque[T]) -> Option[T] {
  if self.count == 0 {
    return None
  }
  let slot = self.buf[self.head]
  self.buf[self.head] = None
  self.head = (self.head + 1) % self.buf.length()
  self.count = self.count - 1
  slot
}

// Removes and returns the back element (a steal), or None when empty.
//
// Complexity: O(1).
pub fn[T] FixedDeque::pop_back(self : FixedDeque[T]) -> Option[T] {
  if self.count == 0 {
    return None
  }
  let index = (self.head + self.count - 1) % self.buf.length()
  let slot = self.buf[index]
  self.buf[index] = None
  self.count = self.count - 1
  slot
}

// Returns the front element without removing it, or None when empty.
pub fn[T] FixedDeque::peek_front(self : FixedDeque[T]) -> Option[T] {
  if self.count == 0 {
    return None
  }
  self.buf[self.head]
}

// Returns the back element without removing it, or None when empty.
pub fn[T] FixedDeque::peek_back(self : FixedDeque[T]) -> Option[T] {
  if self.count == 0 {
    return None
  }
  self.buf[(self.head + self.count - 1) % self.buf.length()]
}

test "deque: fifo via push_back and lifo via push_front" {
  let deque = FixedDeque::with_capacity(8)
  assert_true(deque.push_back(1))
  assert_true(deque.push_back(2))
  assert_true(deque.push_back(3))
  assert_eq(deque.pop_front(), Some(1))
  assert_eq(deque.pop_front(), Some(2))
  assert_eq(deque.pop_front(), Some(3))
  assert_true(deque.pop_front() is None)
  assert_true(deque.push_front(1))
  assert_true(deque.push_front(2))
  assert_true(deque.push_front(3))
  assert_eq(deque.pop_front(), Some(3))
  assert_eq(deque.pop_front(), Some(2))
  assert_eq(deque.pop_front(), Some(1))
  assert_true(deque.pop_front() is None)
}

test "deque: both ends mix correctly" {
  let deque = FixedDeque::with_capacity(8)
  assert_true(deque.push_front("a"))
  assert_true(deque.push_back("b"))
  assert_true(deque.push_front("c"))
  assert_eq(deque.pop_front(), Some("c"))
  assert_eq(deque.pop_back(), Some("b"))
  assert_eq(deque.pop_front(), Some("a"))
  assert_true(deque.pop_back() is None)
}

test "deque: wrap-around at both ends" {
  let deque = FixedDeque::with_capacity(3)
  assert_true(deque.push_front(1))
  assert_true(deque.push_front(2))
  assert_true(deque.push_front(3))
  assert_false(deque.push_back(9), msg="full deque rejects pushes")
  assert_eq(deque.pop_back(), Some(1))
  assert_true(deque.push_back(4))
  assert_eq(deque.pop_front(), Some(3))
  assert_eq(deque.pop_front(), Some(2))
  assert_eq(deque.pop_back(), Some(4))
  assert_true(deque.is_empty())
}

// A work-stealing scheduler in miniature: the owner pops from the
// front (LIFO, cache-friendly), a thief steals from the back (FIFO).
// Single-threaded here, but the two access patterns are exactly the
// ones the real scheduler uses. Every task must be processed exactly
// once, none lost.
test "deque: work-stealing pattern processes every task exactly once" {
  let deque = FixedDeque::with_capacity(32)
  let total = 30
  for t = 1; t <= total; t = t + 1 {
    assert_true(deque.push_front(t))
  }
  assert_eq(deque.len(), total)
  let seen = FixedArray::make(total + 1, false)
  let mut processed = 0
  let mut owner_turn = true
  let mut steps = 0
  while processed < total {
    guard steps < 64 else { abort("deque test: no progress in work-stealing loop") }
    steps = steps + 1
    let task = if owner_turn {
      owner_turn = false
      deque.pop_front()
    } else {
      owner_turn = true
      deque.pop_back()
    }
    match task {
      None => ()
      Some(t) => {
        assert_false(seen[t], msg="task processed twice")
        seen[t] = true
        processed = processed + 1
      }
    }
  }
  assert_true(deque.is_empty())
  for t = 1; t <= total; t = t + 1 {
    assert_true(seen[t], msg="task was never processed")
  }
}

test "deque: peek does not consume" {
  let deque = FixedDeque::with_capacity(4)
  assert_true(deque.push_back(10))
  assert_true(deque.push_front(20))
  assert_eq(deque.peek_front(), Some(20))
  assert_eq(deque.peek_back(), Some(10))
  assert_eq(deque.len(), 2)
}

test "deque: zero capacity is a valid empty deque" {
  let deque = FixedDeque::with_capacity(0)
  assert_true(deque.is_empty())
  assert_true(deque.is_full())
  assert_false(deque.push_front(1))
  assert_false(deque.push_back(1))
  assert_true(deque.pop_front() is None)
  assert_true(deque.pop_back() is None)
  assert_true(deque.peek_front() is None)
  assert_true(deque.peek_back() is None)
}
