// A miniature authoritative game server: the end-to-end demo of
// moonbase. Every module plays its natural role in one tick loop:
//
//   module            role here
//   ----------------  --------------------------------------------------
//   SlabAllocator     entity payload pool (one 16 B block per entity:
//                     byte 0 = x, byte 1 = y, byte 2 = hp; bytes 3..15
//                     reserved for growth — realistic per-entity
//                     headroom)
//   SparseSet         the alive set: O(1) membership for every query,
//                     O(alive) walks for systems
//   BitVec            dirty flags: who changed this tick, who to
//                     broadcast; popcnt() = change count
//   RingBuffer        the bounded client event queue — full means the
//                     event is dropped (a full server sheds load, it
//                     never blocks)
//   FixedDeque        the per-tick task queue: owner pushes front
//                     (LIFO, cache-hot), an idle worker steals from the
//                     back (FIFO) — the work-stealing pattern
//   Arena             the per-tick broadcast command buffer: allocated
//                     wholesale, reset at tick end
//
// The test below runs 200 ticks of randomized client traffic against
// this server while a model mirrors every state transition (including
// the allocator's LIFO block hand-out), then checks per tick: alive set
// == pool usage, payload bytes == model, every task processed exactly
// once, every dirty flag cleared, commands == dirty count, zero arena
// overflow, and the model ring agreeing with the server ring on every
// drop decision.

pub struct Event {
  kind : Int // 0 = join (dx/dy carry the spawn position), 1 = leave, 2 = move
  id : Int   // block index for leave/move
  dx : Int   // spawn x for join, x step (-2..=2, clamped) for move
  dy : Int   // spawn y for join, y step (-2..=2, clamped) for move
}

pub struct GameServer {
  entities : @mem.SlabAllocator
  alive : @collections.SparseSet
  dirty : @collections.BitVec
  events : @collections.RingBuffer[Event]
  tasks : @collections.FixedDeque[Int]
  commands : @mem.Arena[Int]
  mut tick_n : Int
  mut processed : Int      // tasks run in the last tick
  mut last_commands : Int  // commands broadcast in the last tick
  mut cmd_overflow : Int   // broadcasts lost because the arena was full
}

// Pool size in blocks (also the entity id universe).
const POOL : Int = 64
// Bytes per entity block (payload uses bytes 0..2).
const BLOCK : Int = 16
// Event queue capacity. Full = drop (bounded load shedding).
const EVENT_CAP : Int = 32
// Task queue capacity; must exceed the pool size (one task per alive
// entity per tick).
const TASK_CAP : Int = 128
// Command arena capacity; must exceed the pool size.
const CMD_CAP : Int = 128
// Events drained per tick (bounded work per tick).
const DRAIN_PER_TICK : Int = 4
// Initial hit points of a spawned entity.
const SPAWN_HP : Int = 100

pub fn GameServer::new() -> GameServer {
  {
    entities: @mem.SlabAllocator::new(POOL, BLOCK),
    alive: @collections.SparseSet::with_capacity(POOL),
    dirty: @collections.BitVec::with_capacity(POOL),
    events: @collections.RingBuffer::with_capacity(EVENT_CAP),
    tasks: @collections.FixedDeque::with_capacity(TASK_CAP),
    commands: @mem.Arena::with_capacity(CMD_CAP),
    tick_n: 0,
    processed: 0,
    last_commands: 0,
    cmd_overflow: 0,
  }
}

// Queues one client event. Returns false when the queue is full — the
// event is dropped, which is the documented load-shedding behavior.
pub fn GameServer::push_event(self : GameServer, e : Event) -> Bool {
  self.events.push(e)
}

// Runs one tick: drain events, schedule one task per alive entity,
// run the tasks (work-stealing pattern), decay hp every 10th tick, and
// reset the command arena.
pub fn GameServer::tick(self : GameServer) -> Unit {
  for _i = 0; _i < DRAIN_PER_TICK; _i = _i + 1 {
    match self.events.pop() {
      None => break
      Some(e) => self.apply_event(e)
    }
  }
  self.schedule_tasks()
  self.run_tasks()
  if self.tick_n % 10 == 9 {
    self.decay_pass()
  }
  self.last_commands = self.commands.len()
  self.commands.reset()
  self.tick_n = self.tick_n + 1
}

fn GameServer::apply_event(self : GameServer, e : Event) -> Unit {
  if e.kind == 0 {
    // join: hand out the next free block, write the payload bytes.
    match self.entities.alloc() {
      None => () // pool full: the join is rejected, nothing to clean up
      Some(off) => {
        let id = off / BLOCK
        match self.alive.insert(id) {
          false => abort("join into a live block: allocator/alive-set desync")
          true => ()
        }
        let storage = self.entities.storage()
        storage[off] = (clamp_axis(e.dx)).to_byte()
        storage[off + 1] = (clamp_axis(e.dy)).to_byte()
        storage[off + 2] = (SPAWN_HP).to_byte()
        self.dirty.set(id, true)
      }
    }
  } else if e.kind == 1 {
    // leave: return the block and drop the membership.
    let id = e.id
    if self.alive.remove(id) {
      self.entities.free(id * BLOCK)
      self.dirty.set(id, false)
    }
  } else {
    // move: step the payload bytes, clamped to the 16x16 grid.
    let id = e.id
    if self.alive.contains(id) {
      let off = id * BLOCK
      let storage = self.entities.storage()
      storage[off] = (clamp_axis(storage[off].to_int() + e.dx)).to_byte()
      storage[off + 1] = (clamp_axis(storage[off + 1].to_int() + e.dy)).to_byte()
      self.dirty.set(id, true)
    }
  }
}

// The owner schedules one task per alive entity, pushing at the front
// (LIFO — freshest first, cache-hot). Capacity exceeds the pool, so a
// full queue would be an internal invariant violation.
fn GameServer::schedule_tasks(self : GameServer) -> Unit {
  for i = 0; i < self.alive.len(); i = i + 1 {
    let id = self.alive.get(i)
    match self.tasks.push_front(id) {
      true => ()
      false => abort("task queue overflow: TASK_CAP must exceed POOL")
    }
  }
}

// Drains the task queue alternating owner (pop front, LIFO) and thief
// (pop back, FIFO) — the exact access pattern of a work-stealing
// scheduler. Every task is a dirty check + broadcast; the dirty flag is
// cleared as the broadcast happens, so the flag also serves as the
// processing guard.
fn GameServer::run_tasks(self : GameServer) -> Unit {
  let mut owner_turn = true
  let mut processed = 0
  while !self.tasks.is_empty() {
    let task = if owner_turn {
      owner_turn = false
      self.tasks.pop_front()
    } else {
      owner_turn = true
      self.tasks.pop_back()
    }
    match task {
      None => ()
      Some(id) => {
        processed = processed + 1
        if self.dirty.get(id) {
          self.dirty.set(id, false)
          let off = id * BLOCK
          let storage = self.entities.storage()
          let command = pack_command(id, storage[off].to_int(), storage[off + 1].to_int())
          match self.commands.alloc(command) {
            None => self.cmd_overflow = self.cmd_overflow + 1
            Some(_) => ()
          }
        }
      }
    }
  }
  self.processed = processed
}

// Every 10th tick: walk the alive set and decay hp through the payload
// byte. At 1 hp the entity despawns: block returned, membership
// dropped, flag cleared. Iteration is swap-remove safe: after a
// despawn the index is re-examined.
fn GameServer::decay_pass(self : GameServer) -> Unit {
  let mut i = 0
  while i < self.alive.len() {
    let id = self.alive.get(i)
    let off = id * BLOCK
    let storage = self.entities.storage()
    let hp = storage[off + 2].to_int()
    if hp == 1 {
      self.entities.free(off)
      self.dirty.set(id, false)
      match self.alive.remove(id) {
        _ => ()
      }
    } else {
      storage[off + 2] = storage[off + 2] - (1).to_byte()
      i = i + 1
    }
  }
}

// Clamps an axis to the 16x16 grid.
fn clamp_axis(v : Int) -> Int {
  if v < 0 {
    0
  } else if v > 15 {
    15
  } else {
    v
  }
}

// Packs a broadcast command: id (8 bits) | x (4 bits) | y (4 bits).
fn pack_command(id : Int, x : Int, y : Int) -> Int {
  (id << 8) | (x << 4) | y
}

// Deterministic pseudo-random generator for reproducible tests (LCG).
fn next_rand(seed : Ref[Int]) -> Int {
  seed.val = (seed.val * 1103515245 + 12345) & 0x7FFF_FFFF
  seed.val
}

test "examples: 200-tick game server keeps every invariant" {
  let server = GameServer::new()
  // The model: mirrors of x/y/hp/alive/dirty plus a replica of the
  // allocator's LIFO block hand-out (stack: top = next free block).
  let alive_m = FixedArray::make(POOL, false)
  let x_m = FixedArray::make(POOL, 0)
  let y_m = FixedArray::make(POOL, 0)
  let hp_m = FixedArray::make(POOL, 0)
  let dirty_m = FixedArray::make(POOL, false)
  let free_stack = FixedArray::make(POOL, 0)
  let mut top = 0
  for i = POOL - 1; i >= 0; i = i - 1 {
    free_stack[top] = i
    top = top + 1
  }
  // The model's own event ring: same capacity, same drain pattern, so
  // every drop decision must agree with the server's.
  let model_ring = @collections.RingBuffer::with_capacity(EVENT_CAP)
  let seed = Ref(20260925)
  let mut generated = 0
  let mut dropped = 0
  for tick = 0; tick < 200; tick = tick + 1 {
    // 1. Inject five client events (more than the per-tick drain, so
    //    the queue backs up and drops are guaranteed to occur).
    for _i = 0; _i < 5; _i = _i + 1 {
      let e = Event::{
        kind: next_rand(seed) % 3,
        id: next_rand(seed) % POOL,
        dx: next_rand(seed) % 5 - 2,
        dy: next_rand(seed) % 5 - 2,
      }
      generated = generated + 1
      let ok = server.push_event(e)
      assert_eq(ok, model_ring.push(e), msg="server and model must agree on drops")
      if !ok {
        dropped = dropped + 1
      }
    }
    // 2. The model drains the same events the server will this tick
    //    and applies them to the mirrors.
    for _i = 0; _i < DRAIN_PER_TICK; _i = _i + 1 {
      match model_ring.pop() {
        None => break
        Some(e) => {
          if e.kind == 0 {
            if top > 0 {
              top = top - 1
              let id = free_stack[top]
              alive_m[id] = true
              x_m[id] = clamp_axis(e.dx)
              y_m[id] = clamp_axis(e.dy)
              hp_m[id] = SPAWN_HP
              dirty_m[id] = true
            }
          } else if e.kind == 1 {
            let id = e.id
            if alive_m[id] {
              alive_m[id] = false
              free_stack[top] = id
              top = top + 1
              dirty_m[id] = false
              x_m[id] = 0
              y_m[id] = 0
              hp_m[id] = 0
            }
          } else {
            let id = e.id
            if alive_m[id] {
              x_m[id] = clamp_axis(x_m[id] + e.dx)
              y_m[id] = clamp_axis(y_m[id] + e.dy)
              dirty_m[id] = true
            }
          }
        }
      }
    }
    // 3. Expected broadcasts = entities dirty right now (the server
    //    runs its tasks before the decay pass).
    let mut expected_commands = 0
    for i = 0; i < POOL; i = i + 1 {
      if dirty_m[i] {
        expected_commands = expected_commands + 1
      }
    }
    // Model run_tasks: every alive entity gets one task, and each dirty
    // flag is cleared as its broadcast happens. Every alive entity is
    // scheduled, so all dirty flags end cleared.
    for i = 0; i < POOL; i = i + 1 {
      dirty_m[i] = false
    }
    // Expected tasks = entities alive at schedule time (after this
    // tick's event drain, before the decay pass).
    let mut expected_tasks = 0
    for i = 0; i < POOL; i = i + 1 {
      if alive_m[i] {
        expected_tasks = expected_tasks + 1
      }
    }
    // 4. Run the server tick, then the model's decay pass.
    server.tick()
    if tick % 10 == 9 {
      for i = 0; i < POOL; i = i + 1 {
        if alive_m[i] {
          if hp_m[i] == 1 {
            alive_m[i] = false
            free_stack[top] = i
            top = top + 1
            dirty_m[i] = false
            x_m[i] = 0
            y_m[i] = 0
            hp_m[i] = 0
          } else {
            hp_m[i] = hp_m[i] - 1
          }
        }
      }
    }
    // 5. Check every invariant against the model.
    assert_eq(server.entities.used(), server.alive.len(), msg="pool usage must track the alive set")
    assert_eq(server.processed, expected_tasks, msg="every task must be processed exactly once")
    assert_eq(server.last_commands, expected_commands, msg="broadcast count must match dirty entities")
    assert_eq(server.cmd_overflow, 0, msg="command arena must never overflow")
    assert_eq(server.dirty.popcnt(), 0, msg="every dirty flag must be cleared per tick")
    assert_true(server.tasks.is_empty(), msg="task queue must drain every tick")
    assert_eq(server.commands.len(), 0, msg="command arena must reset every tick")
    let storage = server.entities.storage()
    for i = 0; i < POOL; i = i + 1 {
      assert_eq(server.alive.contains(i), alive_m[i])
      if alive_m[i] {
        let off = i * BLOCK
        assert_eq(storage[off].to_int(), x_m[i])
        assert_eq(storage[off + 1].to_int(), y_m[i])
        assert_eq(storage[off + 2].to_int(), hp_m[i])
      }
    }
  }
  // The whole run: every injected event either got applied or dropped,
  // and the server ring drained in lockstep with the model.
  assert_eq(server.events.len(), model_ring.len(), msg="server and model rings must stay in sync")
  assert_true(generated > 0)
  assert_true(dropped > 0, msg="over-injection must have caused drops")
  assert_eq(server.entities.used(), server.alive.len())
}
