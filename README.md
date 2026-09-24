# moonbase

零依赖、跨后端的 MoonBit 底层基础设施库：块分配器与定容容器。

## 为什么需要它

MoonBit 生态的痛点不是「没有包」，而是「包会烂」：语言演进快，半年不更新的库往往无法编译；活跃维护集中在编译器周边，跨后端、零依赖的通用底层库薄弱。moonbase 用一条红线规避这个问题——**纯 MoonBit，零 FFI，零第三方依赖**，语言怎么迭代它都编译得过。

## 设计原则

1. **零依赖**：不写一行 `extern`，CI 里有硬性检查
2. **跨后端**：native / js / wasm-gc 三目标全测（同样的代码，同样的测试）
3. **契约化 API**（详见 [docs/design.md](docs/design.md)）：
   - `Option`/`Bool` 返回值 = 资源耗尽（OOM、队满）
   - `abort` = 契约违反（越界、误用）
   - 每个公开 API 标注复杂度
4. **句柄而非指针**：分配器返回缓冲区内的字节偏移（`Int`），分配过程本身零 GC 分配

## 模块

| 模块 | 内容 | 状态 |
|---|---|---|
| `@mem.allocator` | `Allocator` trait（alloc/free/reset） | ✅ M0 |
| `@mem.bump` | `BumpAllocator`：O(1) bump 分配，整场 reset | ✅ M0 |
| `@mem.slab` | `SlabAllocator`：固定大小块分配（对象池/每实体内存，双释放检测，LIFO 复用） | ✅ M1 |
| `@mem.buddy` | `BuddyAllocator`：2 的幂可变大小块（malloc 风格，伙伴合并、免 size 释放） | ✅ M1 |
| `@mem.arena` | `Arena[T]`：类型化分配，句柄防悬垂 | 📋 M2 |
| `@collections.ring_buffer` | 定容 FIFO 环形缓冲（SPSC 友好，满则拒绝） | ✅ M0 |
| `@collections.bit_vec` | 定容位向量（`UInt64` 字存储，含 `popcnt`） | ✅ M0 |
| `@collections.sparse_set` | 稀疏集合（ECS 存活实体集：O(1) 增删查，迭代 O(len)） | ✅ M1 |
| `@collections.fixed_deque` | 定容双端队列 | 📋 M1 |

## 快速开始

```bash
moon add moonbit-community/moonbase   # 发布后可用
```

```moonbit
let arena = @mem.bump.BumpAllocator::new(1024 * 1024)
match arena.alloc(64, 8) {
  Some(off) => println("block at offset \${off}")
  None => abort("out of memory")
}
arena.reset()  // 整场回收，O(1)
```

## 质量

- `moon check` 零警告（作为 CI 硬性门槛）
- 每个模块配单元测试 + 确定性伪随机序列的属性测试（不变量：不重叠、对齐、FIFO 序）
- 复杂度标注进 API 文档；基准方法见 [docs/benchmarks.md](docs/benchmarks.md)

## 路线图

- **M1**：slab/buddy 分配器、sparse_set、fixed_deque、三后端 CI
- **M2**：`Arena[T]` 类型化分配、基准测试、mooncakes.io 发布
- **M3**：无锁 SPSC 队列（依赖 core 原子操作的可用性）、性能文档

## 许可

Apache-2.0

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)。本仓库的代码由 AI 辅助生成、人工审查核验——审查清单也写在 CONTRIBUTING.md 里。
