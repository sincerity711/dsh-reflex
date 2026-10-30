# 资源占用

测量方法：`dsh-reflex bench --duration 60s --interval 2s --label <场景> --out docs/PERF.md`。它通过 `helper.status` 采样 helper 和各程序进程：

- CPU：`proc_pid_rusage`，取相邻两次采样之差；
- RSS 和物理占用（`ri_phys_footprint`，不含共享的系统框架页）；
- 事件延迟：程序 `observedAt` 到 emit 的平均值，来自程序 metrics。

bench 自己每 2 秒查询一次 helper 状态，所以 helper 的数字里包含这部分开销。

## 场景

| 场景 | 状态 |
|---|---|
| 空闲：helper 运行，没有程序 | ✅ 已测（下表） |
| 空闲：teams 已启用，Teams 在运行，不在会中 | ⏳ 要等辅助功能授权后在本机测 |
| 会中、未采集（没有规则引用 capture） | ⏳ 同上 |
| 会中、采集字幕 | ⏳ 同上（真实会议） |

## 结果

### helper idle（无程序、未授权 AX）· 2026-10-09 · 16s

| 进程 | CPU 平均 | CPU 峰值 | RSS 平均 | RSS 峰值 | 物理占用（footprint）平均 | 事件延迟（平均） |
|---|---|---|---|---|---|---|
| helper | 0.14% | 0.30% | 37.8MB | 37.9MB | 9.1MB | — |
