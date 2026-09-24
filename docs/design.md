# 设计文档

## 1. 定位

moonbase 是 MoonBit 的底层基础设施库：为嵌入式、游戏、运行时、编译器这类「GC 不友好」场景提供确定性内存管理与定容容器。它是 MoonBit 生态里少有的**零依赖、跨三后端**的库——纯 MoonBit 实现，语言演进不影响它编译。

## 2. 核心决策

### 2.1 内存来自 `FixedArray[Byte]` 缓冲区

缓冲区统一用 `FixedArray[Byte]`（`Bytes` 不支持按下标写入，无法承载载荷字节），不需要任何 FFI。分配器在缓冲区上管理块，因此：

- 确定性：不触碰 GC 堆（构造期除外），分配行为可预测
- 跨后端：native / js / wasm-gc 三个后端行为一致
- 未来若 MoonBit 支持裸机/嵌入式目标，本库可以直接跟上（无 FFI 依赖是前提）

### 2.2 句柄而非指针

分配器返回缓冲区内的**字节偏移（`Int`）**而非指针：

- 杜绝悬垂引用：reset 后旧句柄只是「语义失效」，不会造成内存安全破坏
- 分配本身零 GC 分配，可在热路径使用
- 调用方通过 `storage()` 取到缓冲区视图，用 `storage()[off]` 读写载荷字节；块范围 [off, off + size) 归分配者所有，写越界是契约违反
- `free`/`reset` 不触碰载荷字节（有测试锁定）：数据保留到块被下次 `alloc` 重新交出为止

### 2.3 契约约定

| 情形 | 表达 | 理由 |
|---|---|---|
| 资源耗尽（OOM、队满） | `Option`/`Bool` | 正常控制流，调用方必须处理 |
| 契约违反（越界、负参数、误用） | `abort` | 程序 bug，尽早暴露 |

`free` 可能为 no-op（bump 分配器）：与 Zig `FixedBufferAllocator` 的 arena 语义一致，
让泛型于 `Allocator` 的代码不会因具体实现而崩溃。

### 2.4 对齐语义（M0 边界）

当前对齐保证是**相对缓冲区起点**的对齐。绝对内存对齐（如 16 字节 SIMD 对齐）
依赖缓冲区自身的对齐，属于 M2+ 的改进项，届时在 `FixedArray` 布局确定后补充。

## 3. 复杂度总表

| 操作 | Bump | Slab | Buddy | Arena | RingBuffer | BitVec | SparseSet | FixedDeque |
|---|---|---|---|---|---|---|---|---|
| alloc | O(1) | O(1) | O(log n) | O(1) | — | — | — | — |
| free | O(1)（no-op） | O(1) | O(log n) | —（整场 reset） | — | — | — | — |
| reset | O(1) | O(n) | O(n) | O(n) | — | — | — | — |
| storage | O(1) | O(1) | O(1) | — | — | — | — | — |
| push/pop/peek | — | — | — | — | O(1) | — | — | O(1)（两端） |
| get/set | — | — | — | O(1) | — | O(1) | — | — |
| popcnt | — | — | — | — | — | O(n/64) | — | — |
| insert/remove/contains | — | — | — | — | — | — | O(1) | — |
| 迭代（len/get） | — | — | — | — | — | — | O(len) | — |
| clear | — | — | — | — | — | — | O(len) | — |

最坏情况碎片：bump 每次分配 ≤ align-1 字节。

## 4. 测试策略

- **确定性伪随机属性测试**：LCG 种子固定 → 任何环境下重放一致；随机操作序列后校验不变量（不重叠、对齐、FIFO 序、popcnt 一致性）
- **三后端矩阵**：同一套测试在 native / js / wasm-gc 上全部运行
- **零 FFI 门禁**：CI 中 `grep extern` 出现即失败

## 5. M1 模块设计

### 5.1 SlabAllocator：固定大小块

- 自由链表放在与缓冲区平行的 `next[]`（`FixedArray[Int]`）里，alloc/free 不触碰负载字节
- `-2` 哨兵标记已分配块 → 双重释放可检测，直接 `abort`（而不是静默破坏链表）
- LIFO 复用：最近释放的块最先被再分配，热块保持缓存驻留
- 通过 `Allocator` trait 使用：size ≤ block_size、align 整除 block_size，否则 `None`
- 应用场景：对象池、每实体/每帧内存（游戏服务端、嵌入式固件）

### 5.2 BuddyAllocator：2 的幂可变大小块

- 经典 `longest[]` 二叉树：每个节点记录子树内最大连续空闲块；分配向下找最贴合块
- 向上传播规则：两半子树都**满空闲**时父节点合并为整块（`left == half && right == half`），否则取较大子值 —— 保证全释放后整块缓冲区恢复为单一空闲块，外部碎片不累积
- 块天然按自身大小对齐（伙伴分裂的不变量），故 align 只需整除 `min_block`，更粗的对齐一律 `None`
- 释放**不需要 size 参数**：从叶子上溯，第一个值为 0 的节点就是被分配的节点（与 C `free` 的 API 相比少一个出错来源）
- 契约边界：释放未分配的偏移会在可检测时 `abort`；释放块**内部**的偏移属于未定义行为（同 C `free` 错误指针），文档标注
- 请求向上取整到 2 的幂（内部碎片 < 2x）；记账开销 = 每树节点一个 `Int`（64 B 最小块时约 25% @ 64-bit Int）
- 应用场景：运行时/内核级内存管理、长期运行服务的可变大小分配（malloc 风格）

### 5.3 SparseSet：稀疏集合

- dense/sparse 双数组：`sparse[v] = dense 下标 + 1`（0 = 不存在）；insert/remove/contains 全部 O(1)
- 迭代 O(len) 而非 O(range)：百万实体宇宙、一万存活实体的 ECS 每帧遍历只花一万步
- 明确记录的取舍：remove 用「末位元素填洞」保持 O(1) → 迭代顺序不保证；clear 是 O(len)（清零存活值的 sparse 反向引用），换来 `contains` 在 clear 后仍然精确 —— O(1) clear 的变体要么只适合「只迭代」用法，要么 contains 返回陈旧结果
- 应用场景：ECS 存活实体集、脏标记跟踪、自由列表索引

### 5.4 FixedDeque：定容双端队列

- work-stealing 调度器的基础结构（Go 运行时、tokio 同款模式）：owner 在前端 push/pop（LIFO，新任务缓存热），thief 从后端偷（FIFO，最老最冷的任务，减少与 owner 争用）
- 满则拒绝（返回 false），不覆盖不等待；所有操作 O(1)；单 owner / 多 thief 使用下结构本身无需加锁（跨线程内存序不在本库范围）
- 与 RingBuffer 的分工：RingBuffer 是严格 FIFO（SPSC 友好），FixedDeque 支持两端操作
- 应用场景：任务窃取队列、撤销/回退栈、双端事件缓冲

### 5.5 Arena[T]：类型化整场分配

- 底层分配器的类型化上层：`alloc` 存值返回整数句柄（下标），句柄无法悬垂到已释放内存 —— reset 后旧句柄在 `get` 上直接 `abort`（响亮失败而不是读垃圾）
- 不支持逐槽释放（bump 生命周期语义）：整场 reset 回收，匹配「每帧临时对象」「编译器阶段产物」的生存期
- `reset` 清空全部槽位（O(len)）——GC 后端上引用在 reset 时立即死亡，而不是等到下次覆写
- 应用场景：每帧绘制列表/命令缓冲、编译器 AST/中间表示、请求级临时数据

## 6. 端到端演示（src/examples/）

一个迷你权威游戏服务器把六个模块组合进同一个 tick 循环（每个模块的角色见
game_server.mbt 文件头），回答「这些积木怎么拼」的问题：

- **SlabAllocator** = 实体载荷池（每实体 16B 块：x/y/hp 三个字节 + 增长余量）
- **SparseSet** = 存活集（O(1) 成员查询，O(alive) 系统遍历）
- **BitVec** = 脏标记（谁变了就广播谁，popcnt = 变化数）
- **RingBuffer** = 有界客户端事件队列（满即丢弃 = 过载降级，永不阻塞）
- **FixedDeque** = 每 tick 任务队列（owner 前入 LIFO、worker 后窃取 FIFO）
- **Arena** = 每 tick 广播命令缓冲（整场分配、tick 末 reset）

测试用模型镜像全部状态转移（含分配器的 LIFO 发块顺序与事件环形队列的丢弃决策），
跑 200 tick 随机客户端流量，逐 tick 断言：存活集与池用量一致、载荷字节与模型一致、
每任务恰好执行一次、脏标记全清、广播数等于脏实体数、命令 arena 零溢出、模型环与
服务器环对每次丢弃意见一致。这是模块级测试之上的组合级验证。
