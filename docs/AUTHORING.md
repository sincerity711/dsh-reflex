# 用 ReflexKit 写程序

程序是一个小 Swift 可执行文件：读取某个 App 的 UI，发出业务事件，执行规则交给它的任务。加一个新 App 就是加一个程序，helper 和插件都不用改。参考实现：[programs/browser](../programs/browser)（简单）、[programs/teams](../programs/teams)（完整）。

## 流程

1. **生成模板**
   ```bash
   dsh-reflex program new myapp --app com.example.App [--dir programs/myapp]
   ```
2. **看结构**（需要 helper 已授权，并先 `dsh-reflex dev on`）
   ```bash
   dsh-reflex ax inspect --app com.example.App [--depth 12] [--nodes 3000] [--json]
   ```
   输出有边界、已脱敏的 UI 树，包括 role、`#DOM id`、`.class`、控件名。用它来找选择器。Chromium/Electron/WebView 应用要先 `dsh-reflex ax wake --app …` 唤醒 DOM 树。
3. **录样本**
   ```bash
   dsh-reflex ax record --app com.example.App --duration 60s --out programs/myapp/Fixtures/sample.jsonl [--keep '#list' --keep '.row']
   ```
   录制期间回车可以加标记（先输入标记文字再回车）。文本默认伪名化：同一个词总是映射成同一个假词，前缀关系保持不变。
4. **写程序和测试**：用 `ProgramHarness` 在样本上回放，断言发出的事件和任务结果。
   ```bash
   dsh-reflex program test programs/myapp     # 即 swift test
   ```
5. **安装**（默认**不启用**）
   ```bash
   dsh-reflex program install programs/myapp  # 构建 release、导出 manifest、lint、安装
   ```
6. **由用户启用**：用户在 DSH 里执行 `/reflex program enable myapp`，看过申请的 App、能力和动作后输入确认码。AI 可以写、可以测，但不能启用程序，也不能扩大权限：manifest 申请的超出已确认范围时，程序不会运行。
7. **调试**：`dsh-reflex program run myapp --dev` 实时输出日志（程序需已启用）。改完重新 `program install`，只重启这一个程序。

## 程序形态

```swift
import ReflexKit

@main
struct MyApp: ReflexProgram {
  static let manifest = Manifest(
    id: "myapp",                         // 小写，作为事件前缀
    version: "0.1.0",
    apps: ["com.example.App"],           // 只能读这些 App
    capabilities: [.read],               // .read | .prepareWeb | .perform
    emits: ["myapp.thing.happened"],     // 事件类型必须以 "<id>." 开头
    tasks: ["collect"],
    config: ["pollSec": 2])              // 默认配置，用户配置覆盖它

  // 常驻：识别状态，发出业务事件。ctx 停止时返回。
  func watch(_ ctx: ProgramContext) async throws {
    for try await tick in ctx.ticks("main", every: .seconds(2), notifications: [AXNotification.titleChanged]) {
      for app in ctx.ax.apps() { /* 读 UI，必要时 ctx.emit(...) */ }
    }
  }

  // 任务：由规则启动；运行到完成或收到停止信号（ctx.isStopping），返回结构化结果。
  func run(task: String, input: JSON, ctx: TaskContext) async throws -> TaskResult {
    for try await update in ctx.watch("rows", every: .seconds(1), idleEvery: .seconds(2), locate: { … }) {
      // update.node：定位到的子树；内容不变时不回调（idleEvery 时给一次 changed=false）
    }
    return .ok(["count": 3], files: [try ctx.file("out.json").path])
  }
}
```

## API 速查

| API | 作用 |
|---|---|
| `ctx.ax.apps()` | 正在运行的、manifest 声明过的 App |
| `ctx.ax.windows(app)` / `windowNodes(app)` | 窗口句柄 / 浅层窗口快照（title、subrole、minimized） |
| `ctx.ax.read(ref, ReadLimits)` | 有边界的子树快照（批量读属性）；每个节点带 `ref` |
| `ctx.ax.find(query, in: ref, FindLimits)` / `findAll` | 深度优先查找，提前结束，有节点数和时间上限 |
| `ctx.ax.parent(of: ref)` | 父元素 |
| `ctx.ax.prepareWeb(app)` | 打开 Chromium / WebView 的 AX 树（每个 pid 按 TTL 最多一次），以 DOM id 出现为准；需要 `.prepareWeb` |
| `ctx.ax.perform(action, on: ref)` | 执行声明过、用户确认过的动作，有审计日志；需要 `.perform` |
| `AXQuery` | `.domId("x")`、`.domClass("c")`、`.role("AXButton")`、`AXQuery.parse("role=AXButton #id .class title^=Meet")` |
| `AXNode` | `first/all(query)`、`parent(ofChildMatching:)`、`texts()`、`contentHash`、`render()` |
| `ctx.ticks(name, every:, notifications:, debounce:)` | 定时 + AX 通知 + App 启动/退出唤醒的循环 |
| `ctx.watch(name, every:, notifications:, idleEvery:, locate:)` | 子树变化（哈希不同）才产出 |
| `ctx.emit(ProgramEvent(...))` | 事件；UI 文字只放 `payload` |
| `ctx.setStatus([...])` | 在 `/reflex status` 里显示 |
| `ctx.checkpoint` | 小型持久化 KV：`save(codable, as:)` / `load(_:from:)`；任务的检查点在任务目录里 |
| `ctx.write/append/writeJSON/file(name)` | 只能写任务目录 |
| `ctx.log.info/warn/error` | 日志（**不要 print**：会被重定向到 stderr） |
| `ctx.clock` / `ctx.sleep(for:)` / `ctx.now` | **必须**用它们，不要用 `Date()` / `Task.sleep`，否则回放测试不能跑在虚拟时间上 |
| `ctx.int/double/string/bool/strings(key, default)` | 读配置 |

## 测试

```swift
let h = try ProgramHarness(MyApp(), fixture: url, config: ["pollSec": 2])
let events = try await h.runWatch()                       // 跑到样本结束
h.advance(to: 4)                                          // 跳到第 4 秒
let r = try await h.runTask("collect", input: [:], stopAt: 46)  // 第 46 秒送达停止信号
```

回放用虚拟时间：循环每要一次下一个 tick，时钟就推进到下一个定时点或下一条录到的通知，并应用那一刻的 UI 树。停止时间点会额外给一次 tick，让程序看到最终状态。也可以手写合成样本（`Fixture(meta:lines:)`），见 `programs/teams/Tests`。

## 约束与经验

- **只读选择器，不点 UI**。动作默认关闭，要用的话在 manifest 里声明 `ActionDecl`，并加 `.perform`。
- **轻量**：先缓存元素句柄（`ref`），失效了再全量查找；全量查找要节流。补偿轮询只在任务期间开启。
- **AX 回调不要阻塞**：循环里的处理器卡住超过 `stallTimeoutSec`，helper 会结束并重启程序。
- **Chromium 不发 AXCreated / AXLayoutChanged**：变化检测用“通知触发 + 目标容器低频补读”。
- **身份**：拿不到稳定 id 时用 `identity: .heuristic`，并在 payload 里写清楚依据。
- 构建时 `dsh-reflex program lint` 会列出绕过 ReflexKit 的调用（直接调 AX API、启动进程、联网、AppleScript、动态加载、合成输入、print）。用户启用前会看到这些。
