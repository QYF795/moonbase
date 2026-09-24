# 基准测试

每个公开模块都配了一个基准工作负载（`src/benchmarks/`），形状与它的场景演示测试一致——测的就是应用实际会发出的访问模式。

## 如何运行

```bash
moon bench                       # 本机默认目标
moon bench --target js
moon bench --target wasm-gc
moon bench --target native --release
```

基准是普通的 test 块，`moon test` 也会执行；`moon bench` 只是入口。CI 在每次 push 时跑 `moon bench --target native --release`，任何基准的编译失败或运行崩溃都会挡住合并。

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
