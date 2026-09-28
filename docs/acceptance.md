# 验收场景（Acceptance Scenarios）

> 本文档供大赛评审与任何复现者使用：每一条质量主张都对应一个可复现的
> 命令与预期结果。所有命令在仓库根目录执行，工具链为最新版 moon
> （CI 每次运行都会现装最新工具链，与 CI 一致）。

## 验收清单

| # | 场景 | 命令 | 预期 |
|---|---|---|---|
| 1 | 三后端功能测试 | `moon test --target js` / `--target wasm-gc` / `--target native` | 42 / 42 全过 |
| 2 | 静态质量 | `moon check` | 零警告 |
| 3 | 端到端演示 | `moon run src/examples --target js` | 确定性输出（见 §3） |
| 4 | 契约行为 | 见 §4 片段 | 资源耗尽 `None`，误用 `abort` |
| 5 | 零 FFI / 零依赖审计 | 见 §5 命令 | 无命中 |
| 6 | 对照基准 | `moon bench --target js`（native 数据在 CI） | 见 [benchmarks.md](benchmarks.md) |
| 7 | CI 全流程 | push 即触发（仓库 Actions） | 七步全绿 |

## 1. 三后端功能测试（42 个）

```
moon test --target js
moon test --target wasm-gc
moon test --target native
```

- 内容：每个模块的**确定性伪随机属性测试**（LCG 固定种子 → 任何环境重放一致，
  随机操作序列后校验不变量）+ **场景演示测试**（200-tick 游戏服务器模型镜像，
  逐 tick 断言 8 项不变量）
- 预期：`Total tests: 42, passed: 42, failed: 0`（native 在本机需要 C 编译器，
  由 CI 的 ubuntu 环境覆盖）
- 另有 2 个基准套件由 `moon bench` 运行（见 §6），不参与上述计数

## 2. 静态质量

```
moon check
```

预期输出 `Finished. moon: …`，**零警告**。仓库红线之一：提交前必须零警告。

## 3. 端到端演示（一键运行）

```
moon run src/examples --target js
```

预期：10 行逐 tick 状态行 + 汇总，输出**完全确定**（固定种子），例如：

```
tick 20: alive=26, queued=20, processed=26, broadcast=2
…
tick 200: alive=60, queued=28, processed=60, broadcast=4
---
200 ticks of randomized client traffic:
  events generated   1000
  events dropped     172   <- bounded load shedding (queue full = drop, never block)
  tasks processed    10299
  commands broadcast 453
  alive at end       60 / 64
  arena overflow     0   <- must stay 0
```

看点：六个模块在同一 tick 循环里协作（角色分工见 `src/examples/game_server.mbt`
文件头）；事件队列满即丢弃（过载降级，永不阻塞）；命令 arena 零溢出。
同场景的状态级验证由测试 1 的 200-tick 模型镜像覆盖。

## 4. 契约行为（资源耗尽与误用）

契约约定：`Option`/`Bool` = 资源耗尽（正常控制流）；`abort` = 契约违反（尽早暴露）。

```moonbit
// 资源耗尽：满池再分配 → None，不 abort
let slab = @mem.SlabAllocator::new(2, 16)
let a = slab.alloc()   // Some(…)
let b = slab.alloc()   // Some(…)
let c = slab.alloc()   // None —— 调用方自行决定降级路径

// 契约违反：双重释放 → abort（响亮失败，而非静默破坏链表）
slab.free(a.unwrap())
slab.free(a.unwrap())  // abort: double free
```

对应测试：`slab.mbt` 的 double-free 检测用例、`bump/slab/buddy/arena` 的
资源耗尽用例、`ring_buffer/fixed_deque` 的队满拒绝用例。

## 5. 零 FFI / 零依赖审计

```
grep -rEn 'extern "C"|extern "wasm"' src      # 预期：无输出
grep -rn '^import\|import {' src/mem src/collections  # 预期：无输出
```

- 零 FFI：库源码无任何 `extern`（CI 有同款门禁，出现即失败）
- 零依赖：库本体（`mem`/`collections`）不 `import` 任何包——连 `moonbitlang/core`
  都不依赖，只使用语言内置类型；仅基准包 `import` core 的 `bench`/`queue`/`hashset`
  用于计时与对照

## 6. 对照基准（moonbase vs core，同工作负载）

`benchmarks/gc_compare.mbt` 把 moonbase 的定容结构与 moonbitlang/core 的动态
GC 结构放在**相同操作序列**下对比：有界 FIFO（RingBuffer vs Queue）、每帧临时
内存（Bump vs 新建 Array）、存活集（SparseSet vs HashSet）。数据与解读见
[docs/benchmarks.md](benchmarks.md)「对照基准」一节；这不是「谁更快」的胜负
声明，而是为两类设计的不同保证（定容 vs 动态扩容）标价。

## 7. CI 全流程

仓库 Actions（https://github.com/QYF795/moonbase/actions）每次 push 运行：

1. `moon check`
2. `moon test --target native`
3. `moon test --target js`
4. `moon test --target wasm-gc`
5. `moon bench --target native --release`（native 基准数据在此日志中）
6. 零 FFI 门禁（grep 出现 extern 即失败）
7. （每次运行现装最新工具链 → 语言演进兼容性持续被验证）
