// BitVec: fixed-capacity bit vector over `FixedArray[UInt64]` words.
//
// Bits are indexed 0..<len. Out-of-range indexes abort (contract
// violation). All operations are O(1) except `popcnt`, which is
// O(len / 64).
pub struct BitVec {
  words : FixedArray[UInt64]
  len : Int
}

// Creates a bit vector holding `bit_capacity` bits, all initially unset.
// Aborts on negative capacity.
pub fn BitVec::with_capacity(bit_capacity : Int) -> BitVec {
  guard bit_capacity >= 0 else { abort("BitVec::with_capacity: negative capacity") }
  let word_capacity = (bit_capacity + 63) / 64
  { words: FixedArray::make(word_capacity, 0UL), len: bit_capacity }
}

// Number of bits this vector holds.
pub fn BitVec::len(self : BitVec) -> Int {
  self.len
}

// Number of bits this vector can hold without growing (never grows;
// equals the construction capacity rounded up to a word boundary).
pub fn BitVec::capacity(self : BitVec) -> Int {
  self.words.length() * 64
}

// Whether the bit at `index` is set. Aborts on out-of-range index.
pub fn BitVec::get(self : BitVec, index : Int) -> Bool {
  self.check_index(index)
  let word = self.words[index / 64]
  (word & (1UL << (index % 64))) != 0UL
}

// Sets or clears the bit at `index`. Aborts on out-of-range index.
pub fn BitVec::set(self : BitVec, index : Int, value : Bool) -> Unit {
  self.check_index(index)
  let word_index = index / 64
  let bit = 1UL << (index % 64)
  if value {
    self.words[word_index] = self.words[word_index] | bit
  } else {
    self.words[word_index] = self.words[word_index] & bit.lnot()
  }
}

// Number of set bits. Complexity: O(len / 64).
pub fn BitVec::popcnt(self : BitVec) -> Int {
  let mut total = 0
  for i = 0; i < self.words.length(); i = i + 1 {
    total = total + self.words[i].popcnt()
  }
  total
}

fn BitVec::check_index(self : BitVec, index : Int) -> Unit {
  if index < 0 || index >= self.len {
    abort("BitVec: index \{index} out of bounds (len = \{self.len})")
  }
}

test "bitvec: set/get roundtrip over every bit" {
  let bits = BitVec::with_capacity(257)
  assert_eq(bits.len(), 257)
  for i = 0; i < 257; i = i + 1 {
    assert_false(bits.get(i))
    bits.set(i, true)
    assert_true(bits.get(i))
  }
  assert_eq(bits.popcnt(), 257)
  for i = 0; i < 257; i = i + 1 {
    bits.set(i, i % 2 == 0)
  }
  assert_eq(bits.popcnt(), 129)
}

test "bitvec: clearing one bit leaves neighbors intact" {
  let bits = BitVec::with_capacity(128)
  for i = 0; i < 128; i = i + 1 {
    bits.set(i, true)
  }
  bits.set(64, false)
  bits.set(65, false)
  assert_false(bits.get(64))
  assert_false(bits.get(65))
  assert_true(bits.get(63))
  assert_true(bits.get(66))
  assert_eq(bits.popcnt(), 126)
}

test "bitvec: word boundary bits work" {
  let bits = BitVec::with_capacity(130)
  bits.set(63, true)
  bits.set(64, true)
  bits.set(127, true)
  bits.set(128, true)
  assert_true(bits.get(63))
  assert_true(bits.get(64))
  assert_true(bits.get(127))
  assert_true(bits.get(128))
  assert_eq(bits.popcnt(), 4)
}
