# 基准测试

## 方法

（M2 建立基准程序后填写）

计划：

- 基准程序位于 `benches/`，用 `moon run` 执行，内部用高精度时钟采样
- 对比对象：MoonBit core 的 `Array`/`Queue` 在等价操作上的耗时
- 场景：
  1. bump alloc + reset 循环（每分配 1 万次）
  2. RingBuffer push/pop 吞吐（容量 64 / 4096）
  3. BitVec set/get/popcnt 吞吐（1M 位）
- 记录格式：每次 PR 追加一行（日期 / commit / 结果），性能回退 ≥10% 需在 PR 中说明

## 历史记录

（暂无——M2 起记录）
