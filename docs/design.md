# 设计文档

## 1. 定位

moonbase 是 MoonBit 的底层基础设施库：为嵌入式、游戏、运行时、编译器这类「GC 不友好」场景提供确定性内存管理与定容容器。它是 MoonBit 生态里少有的**零依赖、跨三后端**的库——纯 MoonBit 实现，语言演进不影响它编译。

## 2. 核心决策

### 2.1 内存来自 `Bytes`/`FixedArray` 缓冲区

`Bytes` 与 `FixedArray[Byte]` 内存布局等价（都是 `byte[]`），且都不需要 FFI。分配器在缓冲区上管理块，因此：

- 确定性：不触碰 GC 堆（构造期除外），分配行为可预测
- 跨后端：native / js / wasm-gc 三个后端行为一致
- 未来若 MoonBit 支持裸机/嵌入式目标，本库可以直接跟上（无 FFI 依赖是前提）

### 2.2 句柄而非指针

分配器返回缓冲区内的**字节偏移（`Int`）**而非指针：

- 杜绝悬垂引用：reset 后旧句柄只是「语义失效」，不会造成内存安全破坏
- 分配本身零 GC 分配，可在热路径使用
- 调用方用 `buf[off]` 风格的视图访问数据

### 2.3 契约约定

| 情形 | 表达 | 理由 |
|---|---|---|
| 资源耗尽（OOM、队满） | `Option`/`Bool` | 正常控制流，调用方必须处理 |
| 契约违反（越界、负参数、误用） | `abort` | 程序 bug，尽早暴露 |

`free` 可能为 no-op（bump 分配器）：与 Zig `FixedBufferAllocator` 的 arena 语义一致，
让泛型于 `Allocator` 的代码不会因具体实现而崩溃。

### 2.4 对齐语义（M0 边界）

当前对齐保证是**相对缓冲区起点**的对齐。绝对内存对齐（如 16 字节 SIMD 对齐）
依赖缓冲区自身的对齐，属于 M2+ 的改进项，届时在 `Bytes` 布局确定后补充。

## 3. 复杂度总表

| 操作 | Bump | Slab | Buddy | RingBuffer | BitVec | SparseSet |
|---|---|---|---|---|---|---|
| alloc | O(1) | O(1) | O(log n) | — | — | — |
| free | O(1)（no-op） | O(1) | O(log n) | — | — | — |
| reset | O(1) | O(n) | O(n) | — | — | — |
| push/pop/peek | — | — | — | O(1) | — | — |
| get/set | — | — | — | — | O(1) | — |
| popcnt | — | — | — | — | O(n/64) | — |
| insert/remove/contains | — | — | — | — | — | O(1) |
| 迭代（len/get） | — | — | — | — | — | O(len) |
| clear | — | — | — | — | — | O(len) |

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
