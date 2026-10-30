# 协议与文件布局

协议版本：插件 ↔ helper `1`，helper ↔ 程序 `1`。

## 文件布局（`$DSH_HOME/reflex`，目录均为 0700）

| 路径 | 说明 |
|---|---|
| `run/helper.json` | helper 的 pid、版本、协议、实际 socket 路径 |
| `run/helper.sock`、`run/helper.token` | helper socket（0600）和本次启动的 token（0600）。路径超过 100 字节时改用 `$TMPDIR/dsh-reflex-<fnv>/helper.sock` |
| `run/helper.lock` | helper 单实例锁（flock） |
| `run/control.sock`、`.token` | 插件控制 socket（leader 才开），给 CLI 用 |
| `run/leader.lock` | 插件 leader 锁 `{pid, host, token, heartbeatAt}` |
| `helper/` | 发件箱 `outbox.jsonl` + `outbox.ack`、`desired.json`、`tasks.json` |
| `helper/DSH Reflex Helper.app` | 安装的 helper |
| `programs/<id>/` | 程序可执行文件 `<id>`、`manifest.json`、`install.json`（来源、哈希、lint 结果） |
| `data/programs/<id>/` | 程序的数据目录（检查点） |
| `data/runs/<runId>/` | `run.json`、每个 step 一个子目录（task 目录、外部程序日志、prompt、reply） |
| `data/runs/index.jsonl` | run 索引 |
| `state/` | `programs.json`（启用与确认）、`sessions.json`（per-correlation 会话映射）、`seen-events.txt` |
| `logs/` | `helper.log`、`programs/<id>.log`、`events-YYYY-MM-DD.jsonl`（已脱敏） |
| `rules.yaml` | 规则 |
| `dev-mode` | 开发模式到期时间（ISO），存在且未过期才允许 inspect / record / sim / dev run |

## 插件 ↔ helper：NDJSON 上的 JSON-RPC 2.0

连接后第一条必须是 `hello`：

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocol":1,"token":"…","client":{"name":"dsh-reflex@desktop","version":"0.1.0","pid":123}}}
```

返回 `{version, protocol, pid, startedAt, bundlePath, axTrusted, devMode, signing:{identity, adhoc}}`。token 不对就断开；协议不符返回错误码 `-32002`（插件会关掉旧 helper 再启动已安装的新版本）。

| 方法 | 参数 | 说明 |
|---|---|---|
| `helper.status` | | 状态汇总：helper 进程信息、programs、tasks、outbox、connections |
| `helper.menuStatus` | | 菜单实际数据匹配诊断：当前会议/任务 ID、字幕条数、缺口与后台屏幕状态；不返回字幕正文或完整任务输入 |
| `helper.requestAccess` | `{openSettings?}` | 弹出授权提示并打开系统设置 |
| `helper.checkAccess` | | 用新的子进程检查授权（避开进程内缓存） |
| `helper.shutdown` / `helper.relaunch` | | |
| `programs.list` / `programs.rescan` | | 已安装程序的 manifest |
| `programs.configure` | `{programs:[{id, enabled, required, config, grantedActions}], replaceAll}` | 下发期望状态 |
| `programs.restart` | `{id}` | 清除失败状态并重启 |
| `programs.devRun` | `{id, on}` | dev 模式：忽略“被规则引用 / App 在运行”两个条件（仍需已启用） |
| `tasks.start` | `{taskId, program, task, input, dir, resumable}` | 同一 taskId 重复调用是幂等的 |
| `tasks.stop` | `{taskId, reason: stopOn\|cancel\|timeout\|shutdown, graceMs}` | 宽限期后强制结束程序进程 |
| `tasks.list` | | |
| `outbox.subscribe` | `{after, takeover}` | 只能有一个消费者；之后推送 `outbox.item` 通知 |
| `outbox.ack` | `{upTo}` | 累计确认 |
| `logs.subscribe` | `{program?}` | 推送 `program.log` |
| `selftest` | `{bundleIds}` | 启动诊断子进程，检查授权继承 |
| `ax.inspect` | `{bundleId, maxDepth?, maxNodes?, redaction?}` | dev 模式 + 白名单 |
| `ax.record` / `.mark` / `.stop` | `{bundleId(s), durationSec, out, intervalSec?, keep?[], keyframeSec?, redaction?}` | dev 模式 + 白名单 |
| `ax.prepareWeb` | `{bundleId}` | dev 模式 |
| `sim.emit` | `{program, event}` | dev 模式：直接写入发件箱，`origin: simulated` |

发件箱条目：

```json
{"seq":12,"id":"01J…","kind":"event","at":"…","data":{ReflexEvent}}
{"seq":13,"id":"result:<taskId>","kind":"task.result","at":"…","data":{"taskId","program","task","status","output","files","error?","stopReason?","startedAt","endedAt"}}
```

`ReflexEvent`：

```ts
{ eventId, eventType, timestamp, observedAt, app: {bundleId, program, pid}, resourceId, correlationId?,
  origin: 'ax'|'poll'|'simulated', identity: 'stable'|'heuristic', dedupeKey?, payload }
```

## helper ↔ 程序：stdin/stdout JSON lines

程序以 `<exe> --reflex-child` 启动。ReflexKit 把真正的 stdout 留给协议，`print` 会被重定向到 stderr，写进程序日志。

helper → 程序：

```json
{"type":"init","programId":"teams","protocolVersion":1,"config":{…},"dataDir":"…","grantedActions":[],"dev":false}
{"type":"task.start","taskId":"…","task":"captureCaptions","input":{…},"dir":"…","resume":false}
{"type":"task.stop","taskId":"…","reason":"stopOn"}
{"type":"ping","seq":7}
{"type":"config","config":{…}}
{"type":"shutdown"}
```

程序 → helper：

```json
{"type":"ready","programId":"teams","version":"0.1.0","protocolVersion":1,"pid":123}
{"type":"event","eventType":"teams.meeting.started","resourceId":"…","correlationId":"…","identity":"heuristic","payload":{…},"observedAt":"…","origin":"ax","dedupeKey":"…"}
{"type":"task.result","taskId":"…","status":"partial","output":{…},"files":["…"],"error":null}
{"type":"task.progress","taskId":"…","progress":{…}}
{"type":"log","level":"info","message":"…","fields":{}}
{"type":"status","status":{…}}
{"type":"pong","seq":7,"metrics":{"axCalls":…,"axMillis":…,"eventsEmitted":…,"avgEventLatencyMs":…,"loops":[{"name","ticks","lastTickAt","stalledSec","avgHandlerMs","maxHandlerMs"}]}}
```

stdin 关闭（helper 退出）时，程序会通知各任务以 `shutdown` 收尾并退出；可续跑的任务以后从检查点继续。

## 录制样本（fixture）

`ax record` 输出 JSONL，`ReplayAX` 回放用的也是这个格式：

```json
{"kind":"meta","version":1,"bundleIds":["com.microsoft.teams2"],"startedAt":"…","redaction":"pseudo","limits":{…},"tool":"ax record","appVersions":{…}}
{"kind":"apps","t":0.0,"apps":[{"pid":2117,"bundleId":"…","name":"…","isActive":false,"isHidden":false}]}
{"kind":"tree","t":0.52,"pid":2117,"root":{AXNode}}
{"kind":"notice","t":0.61,"pid":2140,"name":"AXValueChanged","element":{AXNode}}
{"kind":"marker","t":12.0,"label":"start:covered"}
```

`AXNode` 的字段：`role, subrole, title, desc, value, identifier, domId, domClasses, chromeId, frame, minimized, focused, pid（与父节点不同时才有）, omittedChildren, children`。带 `--keep` 录制时，非关键帧只保留匹配的子树和它的祖先链，窗口只保留一层。

## 会议生命周期命令（2026-10-29）

本机菜单调用 HelperService.meetingCommand；已认证 RPC 客户端可调用 `programs.command`，参数为 `{id:"teams", command:{requestId,correlationId,action,episode?,issuedAt}}`。`issuedAt` 使用 ISO-8601；`action` 为 `end`、`continue` 或 `attach`。`continue` 要求匹配等待 episode。`attach` 只允许从 suppressed 状态显式重新接入，correlationId 必须匹配 status.attachCorrelationId；每次请求用新扫描的会议控件验证，音频本身不能触发接入。成功后生成新的 correlationId 和 started 事件，旧记录不被重开。菜单的结束动作需用户二次确认。命令不挂断 Teams，也不直接停止任务。

helper→program 消息类型 `program.command`，其余字段同 command。程序把命令排入 watch 循环串行处理；program→helper 返回 `program.command.result`，字段 `{requestId,error?,status}`。error 缺失表示已应用，响应超时不能视为成功，重试复用完整请求。请求超过 60 秒拒绝；回执会持久化，重复请求不重做操作。会话过期、等待阶段过期及 requestId 内容冲突均拒绝。

Teams status 增加 `commandsSupported`、`correlationId`、`meeting`、`deadline`、`lostAt`、`episode`、`audio`、`windowEvidence`。旧程序不支持时菜单不显示命令按钮。ended reason 增加 `user_confirmed`、`detection_timeout`，继续使用已有 `teams.meeting.ended` 和 stopOn→字幕收尾→纪要流程。
