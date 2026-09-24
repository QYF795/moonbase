# 选型指南

先回答三个问题，再选模块：

1. 块的尺寸在运行期是**固定的还是变化的**？
2. 生命周期是**逐块释放还是整场回收**？
3. 你要的是**字节块（offset）还是类型化值（句柄）**？

## 分配器怎么选

| 场景 | 选择 | 理由 |
|---|---|---|
| 每帧/每阶段的临时对象，帧末全丢（绘制列表、编译器中间表示） | `@mem.BumpAllocator` | O(1) 分配 + O(1) 整场 reset；没有逐块释放的负担 |
| 每实体一块、实体进出频繁（对象池、游戏服务器实体） | `@mem.SlabAllocator` | O(1) 进出，LIFO 让热块留在缓存里，双释放直接 abort |
| 请求尺寸运行时变化、要防外部碎片（malloc 风格运行时） | `@mem.BuddyAllocator` | 可变大小块 + 伙伴自动合并 + 免 size 释放；代价是 O(log n)，且大块比小块快（树下降浅） |
| 要存类型化值、句柄不能悬垂（帧内对象、请求级数据） | `@mem.Arena` | offset 语义 + 类型安全二合一；reset 立即释放引用（GC 后端上对象在 reset 时死亡） |

决策树：

```
帧末全丢？ ──是── 需要类型化？ ──是── Arena[T]
    │                  └─否── BumpAllocator
    └─否── 块尺寸固定？ ──是── SlabAllocator
                     └─否── BuddyAllocator
```

## 容器怎么选

| 场景 | 选择 | 理由 |
|---|---|---|
| 有界 FIFO、单生产者单消费者、满了就拒绝（事件队列、数据管道） | `@collections.RingBuffer` | 全操作 O(1)，从不覆写；full 返回 false 是天然的过载降级 |
| work-stealing 任务队列（owner LIFO 热任务、thief FIFO 冷任务） | `@collections.FixedDeque` | 两端 O(1)；前入前出/后窃取正是 Go、tokio 调度器的访问模式 |
| 有限值域上的集合、增删查 O(1)、迭代 O(len)（ECS 存活集、脏实体集、空闲索引） | `@collections.SparseSet` | 值域 100 万、存活 1 万时遍历走 1 万步，不是 100 万步 |
| 布尔标志、按位扫描（脏标记、分配位图、集合运算） | `@collections.BitVec` | `UInt64` 字存储 + `popcnt`；注意 js 后端 64 位字运算走软件模拟，热路径慎用（见下） |

## 组合模式（examples 里提炼）

- **对象池 + 存活集**：`SlabAllocator` + `SparseSet`，实体 id 即块下标——O(1) 增删查 + O(1) 块进出 + O(alive) 系统遍历
- **事件进 + 任务出**：`RingBuffer` 收客户端事件（满即降级），`FixedDeque` 分发帧内任务（可被窃取）
- **帧分配 + 帧回收**：`Arena` 存本帧命令缓冲，帧末 reset——与 bump 同生命周期但类型安全

## 后端差异（实测，见 docs/benchmarks.md）

- `BitVec` 在 js 上慢 wasm-gc 百倍量级：js 数值是 Double，`UInt64` 位运算靠软件模拟。**js 热路径上避免高频 `popcnt`/位扫描**；native / wasm-gc 无此问题
- `BuddyAllocator` 的 alloc/free 成本随请求大小变化：请求越大，树下降越浅。同一缓冲上 512B 请求的每对耗时约为 64B 的四成（两个后端一致）
- bump / arena 的每次迭代已接近后端字段写入下限，没有隐藏的线性成本——需要「分配本身可忽略」的帧式内存就选它们

## 什么时候不要用 moonbase

- **需要动态增长**：moonbase 全部定容，容量在构造期定死。要增长去用 core 的 `Array`/`Deque`/`Map`——定容是 moonbase 的保证（确定性、无 GC 抖动），也是它的边界
- **需要跨线程内存序保证**：结构本身无锁且从不覆写（SPSC 友好），但 M3 无锁队列落地前，跨线程可见性由调用方负责
- **需要绝对内存对齐（SIMD 等）**：当前保证是相对缓冲区起点的对齐，绝对对齐是 M2+ 改进项
