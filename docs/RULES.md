# rules.yaml

默认位置 `$DSH_HOME/reflex/rules.yaml`（插件配置 `rulesFile` 可改）。修改后自动重新加载；文件无效时继续用上一份有效规则，`/reflex status` 和 `/reflex rules` 会显示错误。校验：

```bash
dsh-reflex rules validate [file]
```

示例见 [examples/rules](../examples/rules)。

## 结构

```yaml
version: 1
defaults:
  dedupeWindow: 10m        # 默认去重窗口
  maxConcurrentRuns: 8     # 全局同时运行的 run 上限
rules:
  - id: teams-meeting-summary
    enabled: true          # 默认 true
    on: teams.meeting.started          # 或列表；支持 "teams.*"
    when:                              # 可选，全部满足才触发
      payload.title: { contains: "Standup" }   # equals | contains | prefix | regex | exists
    dedupe: { key: "${event.dedupeKey}", window: 10m }
    concurrency: { key: "${event.correlationId}", onBusy: drop, max: 1, maxRuns: 3, queueMax: 10, queueTtl: 1h }
    steps: [ … ]
```

## 去重与并发

- **去重**：同一条规则下，去重键相同、且在窗口期内或仍在运行的 run 只有一个。重复到达的事件挂到原 run 上（`attachedEvents`），不新建。例如程序重启后又发出同一场会议的事件。
- **并发**分三层：全局 `maxConcurrentRuns`；每条规则 `concurrency.maxRuns`；每个并发键 `concurrency.max`（默认 1）。超出时 `onBusy: drop` 丢弃，`queue` 排队（长度上限 `queueMax`，超过 `queueTtl` 就取消）。
- `/reflex pause` 期间不创建新 run，但正在运行的任务仍会收到 `stopOn`。

## 步骤

每个步骤有 `id`、可选的 `timeout`，以及 `next`：按步骤返回的 status 决定下一步，值是步骤 id、`end`（成功结束）或 `fail`；`*` 匹配其他 status。没有写 `next` 时，`ok` 进入下一步，其他 status 视为失败。

### task：由程序执行

```yaml
- id: capture
  task: teams/captureCaptions     # <程序>/<任务>，静态
  input: { title: "${event.payload.title}" }
  stopOn: teams.meeting.ended     # 同一 correlationId（没有则同一 resourceId）的事件到达时，通知任务收尾
  resumable: true                 # 程序或 helper 重启后从检查点续跑
  timeout: 8h                     # 超时先发 stop(timeout)，宽限期后由 helper 强制结束
  next: { ok: summarize, partial: summarize, no_captions: end }
```

返回 `{status, output, files[], error?}`；`output` 只放小数据，大内容放在文件里。

### run：本机外部程序（不经过 shell）

```yaml
- id: notify
  run: { builtin: notify }                      # 或 { argv: ["/abs/path", "arg"], cwd?: …, env?: {K: V} }
  input: { title: "dsh-reflex", message: "字幕不可用：${event.payload.reason}" }
  timeout: 1m
```

约定：环境变量 `REFLEX_INPUT`（输入 JSON 文件）、`REFLEX_RESULT`（结果写到这里）、`REFLEX_RUN_DIR`、`REFLEX_STEP_DIR`。stdin 是控制通道，每行一个 JSON，停止时收到 `{"type":"stop"}`。stdout/stderr 写入 `output.log`。没有写 `result.json` 时，退出码 0 视为 `ok`，否则 `error`。超时或取消时先发 SIGTERM，5 秒后 SIGKILL。`argv[0]` 必须是绝对路径。

内置程序：`notify`（macOS 通知；输入 `title`、`message`、`subtitle`）。

### dsh：DSH 会话

```yaml
- id: summarize
  dsh:
    target: new                    # new | per-correlation | { session: <sessionId> }
    onBusy: queue                  # queue（followup 排到下一轮，不打断）| skip | new-session
    agentPreset: reflex-summarizer # 插件自带：只读文件 + 搜索，无 shell、无 web
    permissionPreset: read-only    # 默认 read-only
    title: "会议纪要 · ${event.payload.title}"
    promptFile: builtin:meeting-summary   # 相对路径先找 rules 所在目录（及其 prompts/），再找插件 prompts/
    files: ["${steps.capture.output.recordPath}"]
    saveReplyTo: "${run.dir}/summary.md"
    inlineFiles: false             # true：把文件内容放进 prompt（给没有文件工具的 preset 用）
  timeout: 30m                     # 超时只把 step 记为 timed_out，不取消会话里正在跑的轮次
```

完成判定：DSH 认领了**这一条**消息（`agent/inbox/claimed`），并且之后回到 idle。回复取最后一条助手消息，写入 `<step>/reply.md`（以及 `saveReplyTo`）。`per-correlation` 让同一 correlationId 的事件进入同一个会话，映射里的会话失效时会重新建。每个会话里待处理的 reflex 消息最多 3 条，再多按 skip 处理。

## 模板

`${…}` 只能用在 `input`、`dsh.title`、`dsh.files`、`dsh.saveReplyTo`、`dedupe.key`、`concurrency.key` 这些数据位置；写在 `on`、`task`、`stopOn`、`run`、`promptFile`、`prompt`、`target` 等位置会被拒绝。

| 变量 | 内容 |
|---|---|
| `event.*` | `eventType`、`resourceId`、`correlationId`、`observedAt`、`dedupeKey`、`app.program`、`payload.*` |
| `steps.<id>.*` | `status`、`output.*`、`files.<n>`、`reply`、`sessionId` |
| `run.id`、`run.dir`、`rule.id`、`now` | |

整串只有一个 `${…}` 时保留 JSON 类型（对象、数字），否则做字符串替换。缺失的值替换为空（整串时为 null）。用在路径里时，来自 `event.*` 的值会被清理成单个路径段（`/`、`..` 等会被替换）。
