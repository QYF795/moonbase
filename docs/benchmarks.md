# 基准测试

每个公开模块都配了一个基准工作负载（`src/benchmarks/`），形状与它的场景演示测试一致——测的就是应用实际会发出的访问模式。

## 如何运行

```bash
moon bench                       # 本机默认目标
moon bench --target js
moon bench --target wasm-gc
moon bench --target native --release
```

基准写成带 `(it : @bench.T)` 参数的 test 块：`moon bench` 运行它们（注入计时器），`moon test` 跳过它们。CI 在每次 push 时跑 `moon bench --target native --release`，任何基准的编译失败或运行崩溃都会挡住合并。

## 测什么

| 基准 | 每次迭代的工作量 | 对应场景 |
|---|---|---|
| bump: 64x32B frame + reset | 64 次 32B 分配 + 整场 reset | 游戏/编译器每帧临时内存 |
| slab: alloc+free 16B blocks | 128 对 alloc/free | 实体池块进出 |
| buddy: alloc+free 64B | 64 对 64B alloc/free | malloc 小对象尺寸类 |
| buddy: alloc+free 512B | 32 对 512B alloc/free | malloc 大对象尺寸类 |
| arena: 64 values + reset | 64 次入 arena + reset | 类型化帧内瞬态对象 |
| ring_buffer: 128 push + 128 pop | 128 入 + 128 出 | 有界 FIFO 半载吞吐 |
| fixed_deque: 64 push_front + 64 pop_back | 64 前入 + 64 后出 | work-stealing 窃取 |
| sparse_set: 256 insert + 256 remove | 256 增 + 256 删 | ECS 存活集抖动 |
| bit_vec: set+scan 4096 bits + popcnt | 4096 置位 + 4096 读 + popcnt | 脏标记簿记 |

结构体在计时闭包**之外**构造：构造成本（buddy 的 O(n) 建树、slab 的 O(n) 建链）是一次性的，不属于这些基准的测量对象。

## 如何读结果

每个基准结束时输出一段 JSON 摘要（`dump_summaries`），关键字段：

- `batch_size`：跑一轮闭包的次数。harness 自动校准，使一个样本 ≈ 100ms
- `mean` / `median`：一个样本（batch_size 次迭代）的耗时
- **每次迭代耗时 = mean / batch_size**（跨基准可比的统一口径）
- `std_dev_pct`：样本间抖动；> 10% 通常意味着后端 GC 或校准干扰，而非结构本身

## 参考数据

2026-09-25 本机实测（Windows 11，moon 0.1.20260920，node 运行 js/wasm-gc；`storage()` 落地后的数字）。每次迭代耗时（ns）：

| 基准 | js (node) | wasm-gc |
|---|---|---|
| bump: 64x32B frame + reset | 2.93 | 6.77 |
| slab: alloc+free 16B blocks | 10.6 | 19.4 |
| buddy: alloc+free 64B | 453 | 652 |
| buddy: alloc+free 512B | 86.8 | 120 |
| arena: 64 values + reset | 3.07 | 2.04 |
| ring_buffer: 128 push + 128 pop | 14.8 | 22.7 |
| fixed_deque: 64 push_front + 64 pop_back | 7.01 | 6.39 |
| sparse_set: 256 insert + 256 remove | 52.6 | 126 |
| bit_vec: set+scan 4096 bits + popcnt | 4.50×10⁶ | 40.8×10³ |

几个诚实读数（也见 docs/perf.md 的选型指南）：

- **buddy 512B 每对比 64B 快**：512B 请求在树里下降 7 层，64B 下降 10 层（65536/512 = 128 叶 vs 1024 叶）——分配成本随树深度变化，不是常数。
- **bit_vec 在 js 上慢百倍**：js 的数值是 Double，64 位字运算走软件模拟；native / wasm-gc 才体现 `UInt64` 的硬件路径。
- bump/arena 的每次迭代已接近后端字段写入的下限，说明它们没有隐藏的线性成本——这正是场景选择它们的原因。

数字会随后端和 moon 版本漂移，**别拿本表当跨库对比的依据**；发布前以 CI 的 native release 数据为准（GitHub Actions 日志）。

## 对照基准（moonbase vs moonbitlang/core，同工作负载）

`benchmarks/gc_compare.mbt` 把 moonbase 的定容结构与 core 的动态 GC 结构放在**相同操作序列**下对比。这不是「谁更快」的胜负声明：两边卖的是不同的保证——core 的容器承担动态扩容/去重语义（moonbase 拒绝），moonbase 的容器承担定容与零分配语义（core 不提供）。同一负载下测到的是**为各自语义付出的成本**，供选型定价。

2026-09-29 本机实测（Windows 11，moon 0.1.20260920，node，`moon bench --target js`）：

| 工作负载 | moonbase | core | 每次操作耗时 |
|---|---|---|---|
| 有界 FIFO：64 push + 64 pop | RingBuffer 511.10 ns | Queue 561.47 ns | 3.99 vs 4.39 ns/op |
| 每帧临时内存：64 × 32B + reset | BumpAllocator 272.49 ns | 新建 Array ×64 611.49 ns | 4.26 vs 9.55 ns/块 |
| 存活集：256 insert + 256 remove | SparseSet 1.94 µs | HashSet 9.48 µs | 3.79 vs 18.5 ns/op |

读法（诚实版）：

- **FIFO 同量级**：两边都是摊销 O(1)，差异是常数因子。选 RingBuffer 的理由不是快，而是**满即拒绝、容量恒定**——core Queue 会随 push 扩容，内存上限不在调用方手里。
- **每帧临时内存约 2.2×**：core 侧每次迭代新建 64 个堆数组（分配 + GC 扫描）；bump 只是偏移推进 + 整场 reset。成本差来自 GC 托管 vs 调用方自管缓冲，而非实现技巧。
- **存活集约 4.9×**：哈希 + 表扩容 vs 双数组下标。SparseSet 的代价是键域必须是连续整数（实体 id），HashSet 没有这个约束——语义换性能。
- **native 数据以 CI 为准**：本机无 C 编译器，native release 数字在 GitHub Actions 日志（workflow 的 `Benchmarks (native, release)` 步骤）。
