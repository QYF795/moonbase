// SparseSet: an O(1) set over a bounded universe of values [0, capacity).
//
// The classic sparse/dense representation behind ECS (entity-component-
// system) runtimes: `dense[]` packs the values actually present, and
// `sparse[]` maps each value to its index in `dense` (plus one, so 0
// means absent). Insert, remove and contains are all O(1); iterating
// costs O(len), not O(capacity) — a million-entity universe with ten
// thousand alive entities is walked in ten thousand steps.
//
// Trade-offs, honestly stated:
// - iteration order is unspecified: remove swaps the last element into
//   the hole to stay O(1)
// - clear() is O(len): it zeroes the sparse entries of live values so
//   `contains` stays exact afterwards (an O(1) clear leaves stale
//   backrefs behind, which either breaks `contains` or only works for
//   iteration-only usage)
//
// Use it for alive sets, free-list indices and dirty tracking — any
// dense-subset-of-large-universe bookkeeping.
//
// Contract: every value must lie in [0, capacity); out-of-range values
// abort. `insert` returns false when the value is already present,
// `remove` when it is absent (resource-style failures, not errors).
pub struct SparseSet {
  dense : FixedArray[Int]
  sparse : FixedArray[Int]
  mut count : Int
}

// Creates an empty set that can hold values in [0, capacity).
// Aborts on negative capacity.
pub fn SparseSet::with_capacity(capacity : Int) -> SparseSet {
  guard capacity >= 0 else { abort("SparseSet::with_capacity: negative capacity") }
  { dense: FixedArray::make(capacity, 0), sparse: FixedArray::make(capacity, 0), count: 0 }
}

// Size of the value universe (values in [0, capacity)).
pub fn SparseSet::capacity(self : SparseSet) -> Int {
  self.sparse.length()
}

// Number of values currently in the set.
pub fn SparseSet::len(self : SparseSet) -> Int {
  self.count
}

pub fn SparseSet::is_empty(self : SparseSet) -> Bool {
  self.count == 0
}

// Whether `value` is in the set. Aborts on out-of-range value.
//
// Complexity: O(1).
pub fn SparseSet::contains(self : SparseSet, value : Int) -> Bool {
  self.check_value(value)
  self.sparse[value] != 0
}

// Adds `value` to the set. Returns false when it is already present.
// Aborts on out-of-range value.
//
// Complexity: O(1).
pub fn SparseSet::insert(self : SparseSet, value : Int) -> Bool {
  self.check_value(value)
  if self.sparse[value] != 0 {
    return false
  }
  self.sparse[value] = self.count + 1
  self.dense[self.count] = value
  self.count = self.count + 1
  true
}

// Removes `value` from the set. Returns false when it is absent.
// Aborts on out-of-range value. Iteration order is unspecified after
// any remove.
//
// Complexity: O(1).
pub fn SparseSet::remove(self : SparseSet, value : Int) -> Bool {
  self.check_value(value)
  let index = self.sparse[value]
  if index == 0 {
    return false
  }
  let last = self.dense[self.count - 1]
  self.dense[index - 1] = last
  self.sparse[last] = index
  self.sparse[value] = 0
  self.count = self.count - 1
  true
}

// Removes every value. `contains` stays exact afterwards.
//
// Complexity: O(len).
pub fn SparseSet::clear(self : SparseSet) -> Unit {
  for i = 0; i < self.count; i = i + 1 {
    self.sparse[self.dense[i]] = 0
    self.dense[i] = 0
  }
  self.count = 0
}

// Returns the i-th value in dense order. Iteration order is unspecified
// (see `remove`); only walk `0 ..< len()` via `get`. Aborts on
// out-of-range index.
//
// Complexity: O(1).
pub fn SparseSet::get(self : SparseSet, index : Int) -> Int {
  if index < 0 || index >= self.count {
    abort("SparseSet: index \{index} out of bounds (len = \{self.count})")
  }
  self.dense[index]
}

fn SparseSet::check_value(self : SparseSet, value : Int) -> Unit {
  if value < 0 || value >= self.sparse.length() {
    abort("SparseSet: value \{value} out of range [0, \{self.sparse.length()})")
  }
}

// Deterministic pseudo-random generator for reproducible tests (LCG).
// Same sequence as the one in @mem's tests.
fn next_rand(seed : Ref[Int]) -> Int {
  seed.val = (seed.val * 1103515245 + 12345) & 0x7FFF_FFFF
  seed.val
}

test "sparse_set: insert, contains and remove roundtrip" {
  let set = SparseSet::with_capacity(8)
  assert_false(set.contains(3))
  assert_true(set.insert(3))
  assert_true(set.insert(7))
  assert_false(set.insert(3), msg="duplicate insert is rejected, not counted")
  assert_eq(set.len(), 2)
  assert_true(set.contains(3))
  assert_true(set.contains(7))
  assert_false(set.contains(0))
  assert_true(set.remove(3))
  assert_false(set.remove(3), msg="removing an absent value reports false")
  assert_eq(set.len(), 1)
  assert_false(set.contains(3))
  assert_true(set.contains(7))
}

test "sparse_set: remove swaps correctly and iteration stays complete" {
  let set = SparseSet::with_capacity(16)
  assert_true(set.insert(1))
  assert_true(set.insert(2))
  assert_true(set.insert(3))
  assert_true(set.remove(2))
  // Whatever the order, both survivors must be reachable by get().
  let seen = FixedArray::make(16, false)
  for i = 0; i < set.len(); i = i + 1 {
    let v = set.get(i)
    assert_false(seen[v], msg="iteration hit the same value twice")
    seen[v] = true
  }
  assert_true(seen[1])
  assert_true(seen[3])
  assert_false(seen[2])
  // The freed slot can be reused immediately.
  assert_true(set.insert(2))
  assert_eq(set.len(), 3)
}

test "sparse_set: clear empties the set and keeps contains exact" {
  let set = SparseSet::with_capacity(64)
  for i = 0; i < 64; i = i + 1 {
    assert_true(set.insert(i))
  }
  set.clear()
  assert_eq(set.len(), 0)
  assert_true(set.is_empty())
  for i = 0; i < 64; i = i + 1 {
    assert_false(set.contains(i), msg="contains must be exact after clear")
  }
  // The set is fully reusable.
  assert_true(set.insert(5))
  assert_eq(set.len(), 1)
  assert_true(set.contains(5))
  assert_false(set.contains(4))
}

// Simulates an ECS runtime's alive-entity bookkeeping: entities spawn
// and despawn at random, and every 10 frames a "system" walks the
// whole alive set the way a component system would — in O(alive)
// steps. The walk must see exactly the mirrored alive set.
test "sparse_set: ECS alive-entity workload" {
  let alive_set = SparseSet::with_capacity(1024)
  let mirror = FixedArray::make(1024, false)
  let seed = Ref(42)
  let mut alive = 0
  for frame = 0; frame < 300; frame = frame + 1 {
    let e = next_rand(seed) % 1024
    if mirror[e] {
      assert_true(alive_set.remove(e))
      mirror[e] = false
      alive = alive - 1
    } else {
      assert_true(alive_set.insert(e))
      mirror[e] = true
      alive = alive + 1
    }
    if frame % 10 == 0 {
      assert_eq(alive_set.len(), alive)
      let mut iter_sum = 0
      for i = 0; i < alive_set.len(); i = i + 1 {
        let e = alive_set.get(i)
        assert_true(mirror[e], msg="iterated entity is not alive")
        iter_sum = iter_sum + e
      }
      let mut mirror_sum = 0
      for e = 0; e < 1024; e = e + 1 {
        if mirror[e] {
          mirror_sum = mirror_sum + e
        }
      }
      assert_eq(iter_sum, mirror_sum, msg="iteration lost or duplicated entities")
    }
  }
}
