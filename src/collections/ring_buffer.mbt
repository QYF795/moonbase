// RingBuffer: fixed-capacity FIFO ring buffer over a `FixedArray`.
//
// `push` returns `false` when the buffer is full — it never overwrites
// and never waits, so a single-producer/single-consumer pair can use it
// as a bounded queue (memory ordering guarantees are out of scope for
// now; see docs/design.md).
//
// All operations are O(1).
pub struct RingBuffer[T] {
  buf : FixedArray[Option[T]]
  mut head : Int
  mut tail : Int
  mut count : Int
}

// Creates an empty buffer that holds at most `capacity` elements.
// Aborts on negative capacity.
pub fn[T] RingBuffer::with_capacity(capacity : Int) -> RingBuffer[T] {
  guard capacity >= 0 else { abort("RingBuffer::with_capacity: negative capacity") }
  { buf: FixedArray::make(capacity, None), head: 0, tail: 0, count: 0 }
}

pub fn[T] RingBuffer::capacity(self : RingBuffer[T]) -> Int {
  self.buf.length()
}

pub fn[T] RingBuffer::len(self : RingBuffer[T]) -> Int {
  self.count
}

pub fn[T] RingBuffer::is_empty(self : RingBuffer[T]) -> Bool {
  self.count == 0
}

pub fn[T] RingBuffer::is_full(self : RingBuffer[T]) -> Bool {
  self.count == self.buf.length()
}

// Appends `value` at the back. Returns `false` (dropping nothing)
// when the buffer is full.
pub fn[T] RingBuffer::push(self : RingBuffer[T], value : T) -> Bool {
  if self.is_full() {
    return false
  }
  self.buf[self.tail] = Some(value)
  self.tail = (self.tail + 1) % self.buf.length()
  self.count = self.count + 1
  true
}

// Removes and returns the front element, or `None` when empty.
pub fn[T] RingBuffer::pop(self : RingBuffer[T]) -> Option[T] {
  if self.count == 0 {
    return None
  }
  let slot = self.buf[self.head]
  self.buf[self.head] = None
  self.head = (self.head + 1) % self.buf.length()
  self.count = self.count - 1
  slot
}

// Returns the front element without removing it, or `None` when empty.
pub fn[T] RingBuffer::peek(self : RingBuffer[T]) -> Option[T] {
  if self.count == 0 {
    return None
  }
  self.buf[self.head]
}

test "ring: fifo order" {
  let q = RingBuffer::with_capacity(4)
  assert_true(q.push(1))
  assert_true(q.push(2))
  assert_true(q.push(3))
  assert_eq(q.pop(), Some(1))
  assert_eq(q.pop(), Some(2))
  assert_eq(q.pop(), Some(3))
  assert_true(q.pop() is None)
}

test "ring: wrap-around reuses freed slots" {
  let q = RingBuffer::with_capacity(3)
  assert_true(q.push("a"))
  assert_true(q.push("b"))
  assert_true(q.push("c"))
  assert_true(q.is_full())
  assert_false(q.push("x"))
  assert_eq(q.pop(), Some("a"))
  assert_eq(q.pop(), Some("b"))
  assert_true(q.push("d"))
  assert_true(q.push("e"))
  assert_eq(q.pop(), Some("c"))
  assert_eq(q.pop(), Some("d"))
  assert_eq(q.pop(), Some("e"))
  assert_true(q.is_empty())
}

test "ring: peek does not consume" {
  let q = RingBuffer::with_capacity(2)
  assert_true(q.push(42))
  assert_eq(q.peek(), Some(42))
  assert_eq(q.peek(), Some(42))
  assert_eq(q.len(), 1)
  assert_eq(q.pop(), Some(42))
  assert_true(q.peek() is None)
}

test "ring: zero capacity is a valid empty buffer" {
  let q = RingBuffer::with_capacity(0)
  assert_true(q.is_full())
  assert_true(q.is_empty())
  assert_false(q.push(1))
  assert_true(q.pop() is None)
}
