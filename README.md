# moonbase

零依赖、跨后端的 MoonBit 底层基础设施库：块分配器与定容容器。

<p align="center">
  <img src="assets/logo-wide.png" width="480" alt="moonbase 砌月 —— 零依赖 · 零 FFI · 用块砌成的月亮">
</p>

## 为什么需要它

moonbitlang/core 已经提供了成熟的**动态 GC 容器**（`Queue`/`Deque`/`HashMap` 等）：自动扩容、GC 托管内存。但「GC 不友好」场景（嵌入式、游戏热路径、编译器运行时）要的是另一组保证：**容量固定、分配时机可控、回收时点确定**。core 的容器在这组保证上是空的。

moonbase 补齐这一侧：**定容、分配路径零堆分配的块分配器与容器**——内存来自调用者提供的固定缓冲区，分配器返回字节偏移句柄，容量用尽即显式拒绝（`Option`/`Bool`），从不静默扩容。与 core 的关系是互补而非竞争：两边的对照基准在 [docs/benchmarks.md](docs/benchmarks.md)。

## 设计原则

1. **零依赖**：库本体（`mem`/`collections`）不 `import` 任何包——连 `moonbitlang/core` 都不依赖，只使用语言内置类型；CI 里有零 FFI 门禁硬性检查
2. **跨后端**：native / js / wasm-gc 三目标全测（同样的代码，同样的测试）
3. **契约化 API**（详见 [docs/design.md](docs/design.md)）：
   - `Option`/`Bool` 返回值 = 资源耗尽（OOM、队满）
   - `abort` = 契约违反（越界、误用）
   - 每个公开 API 标注复杂度
4. **句柄而非指针**：分配器返回缓冲区内的字节偏移（`Int`），分配路径零堆分配——分配/释放本身不创建任何对象，可在热路径使用

## 快速验收

一条命令体验 200-tick 游戏服务器演示，或按 [docs/acceptance.md](docs/acceptance.md) 逐项复现全部质量主张：

```
moon run src/examples --target js
```

## 模块

| 模块 | 内容 | 状态 |
|---|---|---|
| `@mem.Allocator` | `Allocator` trait（alloc/free/reset，资源耗尽返回 `None`） | ✅ M0 |
| `@mem.BumpAllocator` | O(1) bump 分配，整场 reset | ✅ M0 |
| `@mem.SlabAllocator` | 固定大小块分配（对象池/每实体内存，双释放检测，LIFO 复用） | ✅ M1 |
| `@mem.BuddyAllocator` | 2 的幂可变大小块（malloc 风格，伙伴合并、免 size 释放） | ✅ M1 |
| `@mem.Arena` | `Arena[T]`：类型化整场分配（句柄防悬垂、reset 即释放引用） | ✅ M2 |
| `@collections.RingBuffer` | 定容 FIFO 环形缓冲（SPSC 友好，满则拒绝） | ✅ M0 |
| `@collections.BitVec` | 定容位向量（`UInt64` 字存储，含 `popcnt`） | ✅ M0 |
| `@collections.SparseSet` | 稀疏集合（ECS 存活实体集：O(1) 增删查，迭代 O(len)） | ✅ M1 |
| `@collections.FixedDeque` | 定容双端队列（work-stealing 窃取模式：owner 前入前出、thief 后出） | ✅ M1 |
| `bench` | 基准测试套件（9 个真实工作负载，`moon bench` 运行，CI 跑 native release） | ✅ M2 |
| `examples` | 迷你权威游戏服务器：六个模块组合成一个 tick 循环（见 src/examples/） | ✅ M2 |

## 快速开始

```bash
moon add moonbit-community/moonbase   # 发布后可用
```

```moonbit
let arena = @mem.BumpAllocator::new(1024 * 1024)
match arena.alloc(64, 8) {
  Some(off) => {
    arena.storage()[off] = b'!'  // offset 就是 storage 的下标
    println("block at offset \{off}")
  }
  None => abort("out of memory")
}
arena.reset()  // 整场回收，O(1)
```

## 质量

- `moon check` 零警告（作为 CI 硬性门槛）
- 每个模块配单元测试 + 确定性伪随机序列的属性测试（不变量：不重叠、对齐、FIFO 序）
- 复杂度标注进 API 文档；基准方法见 [docs/benchmarks.md](docs/benchmarks.md)，场景选型见 [docs/perf.md](docs/perf.md)

## 路线图

- **M1**：slab/buddy 分配器、sparse_set、fixed_deque、三后端 CI —— 已完成（2026-09）
- **M2**：`Arena[T]` 类型化分配 ✅、基准测试 ✅、mooncakes.io 发布（待账号）
- **M3**：无锁 SPSC 队列（依赖 core 原子操作的可用性）

## 许可

Apache-2.0

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)。本仓库的代码由 AI 辅助生成、人工审查核验——审查清单也写在 CONTRIBUTING.md 里。
