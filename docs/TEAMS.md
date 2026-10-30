# teams 程序

目标：新版 Microsoft Teams（`com.microsoft.teams2`，UI 运行在 Edge WebView2 里）。功能：会议识别、实时字幕采集与整理。数据源是 Teams 的**实时字幕**：只显示在你自己的屏幕上，不会通知其他参会者，Teams 也不保存，所以 reflex 采到的就是唯一的记录。只读文字，不录音也不录像。

> 选择器和窗口行为已在 Teams 26246.1709.5146.8945 上用 `dsh-reflex probe teams --speak` 实测（2026-10-09、10-10），结果见下文“实测结果”和 [VERIFIED.md](VERIFIED.md)。Teams 升级后请重跑探针。

## 2026-10-29：会议保活修复

当前实现以会议控件或可确认归属 Teams 的 CoreAudio 输入进程作为已开始会议的保活证据。窗口消失但音频持续，不结束、不拆会、不倒计时。音频查询不采集声音，也不依据讲话音量；查询失败和系统不支持分别标记为 unknown/unsupported，不能当成确定离会。

两种证据都无法确认时保留任务并等待 120 秒，自动恢复或超时结束；菜单允许续期和提前结束 Reflex 记录。0/负值配置回退 120 秒。标题变化不再立即 replaced；同名标题本身不是会话 ID。实现与边界见 [设计文档](superpowers/specs/2026-10-29-meeting-end-confirmation-design.md)。下面的历史实测描述用于说明 Teams UI 行为，不表示新的会议保活保证。

后台字幕仍依赖 Teams 刷新 AX 树。独立字幕窗口保持可见时，可缓解主窗口最小化的冻结；本次也修复了从已缓存主窗口切换到新弹出字幕窗口的逻辑。所有窗口都隐藏、独立字幕窗口在别的 Space、锁屏场景没有持续采集保证。音频保活不能填补字幕缺口。

## 事件

| 事件 | payload | 说明 |
|---|---|---|
| `teams.meeting.started` | `title`、`startedAt` | `correlationId` = 会议名归一化后的哈希 + 开始时间；`identity: heuristic` |
| `teams.meeting.ended` | `title`、`startedAt`、`endedAt`、`durationSec`、`reason`（`detection_timeout` / `user_confirmed`） | 等待期限届满或手动确认时发出 |

状态栏使用原生 Liquid Glass（macOS 26+；旧系统回退到半透明材质），提供移入后台/带回 Teams 主按钮及实时字幕区。底部“结束记录…”需再次确认，仅结束 Reflex 记录并生成纪要。误点结束后，可使用“采集当前会议”重新接入仍在进行的 Teams 会议；请先展开会议窗口。重新接入会创建一段新记录，原字幕及已完成的处理仍保留，不能补采停止期间已经从 Teams 字幕 UI 消失的内容。

字幕列表读取优先遍历末尾，并恢复成原文档顺序，避免历史内容耗尽 400 节点预算后读不到新字幕。每 2 秒从会议/字幕窗口重新定位列表，防止 Chromium 保留可读的旧容器。文字变化立即保存；菜单在 common run-loop modes 中每 0.5 秒刷新，并在布局后滚动到最新字幕。这些是内部刷新频率，不代表 Teams 语音识别到显示的总延迟。

采集中，标题下显示本段 Reflex 的开始采集时间、记录时长和整段字幕总条数（不是最近显示的 30 条）。时长包含字幕不可用的时段；重新接入后的新记录独立计时，helper 重启继续原时间。没有当前采集时隐藏统计，避免误显示旧会议数据。

“参会人”可展开查看已观察到的姓名。采集器每 15 秒只读会议窗口中已展开的 Participants/Attendees 列表，不改动 Teams 界面；展开 Teams 中的 See more/查看更多后才能读到折叠姓名。显示“31 人 · 已读 20”代表界面人数为 31，但仅取得 20 个姓名。只记录 In this meeting/在此会议中分组，排除邀请、等候大厅、仅加入聊天的成员及展开按钮。名单和变化快照随 checkpoint 持久化，结束后进入 record.json；record.md 汇总已见姓名。关闭面板、虚拟化截断或读取失败不当作离会，快照时间不代表实际加入/离开时间，同名显示名也不等于唯一身份。发言人仍按字幕单独统计。
| `teams.captions.unavailable` | `reason`、`title`（以及 `cause`、`hint`） | `reason`：`no_permission`、`captions_off`、`window_frozen`。`window_frozen` 的 `cause`：`minimized`、`off_screen`、`compact_view`、`stalled` |

## Teams 的窗口

会议期间 Teams 有四类窗口（AX 里的样子）：

| 窗口 | subrole | 标题 | 会议锚点 | 字幕 |
|---|---|---|---|---|
| 会议窗口 | `AXStandardWindow`；**最小化后变成 `AXDialog`** | `会议名 \| Microsoft Teams` | 有 | 字幕区（打开字幕时） |
| 小窗（compact view） | `AXSystemDialog`，浮动；**会议窗口看不见时 Teams 才显示它** | `Meeting compact view \| 会议名 \| Microsoft Teams` | 有 | 无 |
| 弹出的字幕窗口 | `AXSystemDialog`，浮动（始终在最上层） | `会议名 \| Microsoft Teams \| Live captions` | 无 | 有 |
| 主窗口 | `AXStandardWindow` | `Chat \| 当前聊天 \| Microsoft Teams` 等 | 无 | 无 |

macOS 的 `AXWindows` 只列出当前显示中的桌面（Space）上的窗口和最小化的窗口：会议窗口全屏后切到别的桌面，它就不在列表里了。ReflexKit 会把 App 的焦点窗口、主窗口，以及上次列出过、句柄还能读的窗口补进来，标记为 `unlisted`（录制和回放里也保留这个标记）。

程序按结构分类，不依赖本地化的标题文字：有会议锚点（`#hangup-button` / `#call-duration-custom`）的，`AXSystemDialog` 是小窗，其余是会议窗口；没有锚点、但有字幕面板控件（`#captions-settings-menu-trigger-button-non-overflow` 等）或字幕行的，是弹出的字幕窗口。每个窗口在出现、或标题 / subrole / 最小化状态变化时查找一次，之后只重读缓存的句柄确认。

## 会议识别（watch）

- 先用 `prepareWeb` 唤醒 WebView 的 AX 树（同时设 `AXEnhancedUserInterface` 和 `AXManualAccessibility`，不看返回码，以出现 DOM id 为准）。
- 在会议中：存在会议窗口（包括 `unlisted` 的，例如全屏后切到了别的桌面）或小窗。WebView 还没唤醒时，英文界面下标题为 “Meeting with …” 的窗口也算（启发式）。
- 会议名：会议窗口标题去掉 `Microsoft Teams` 这一段。侧窗口在会议名前后加一段（小窗在前，弹出字幕在后），所以在兄弟窗口标题里取最短的、按 ` | ` 分段对齐的前缀或后缀。
- **模态对话框**：会议窗口里弹出模态对话框（例如反馈窗口）时，AX 树里只剩对话框，锚点和字幕都看不到。锚点消失后，标题仍等于当前会议名的窗口在 10 分钟内仍算在会议中。
- 通知只订阅窗口级的（创建、最小化、恢复、焦点窗口变化），其余靠 `scanSec`（2 秒）轮询。Teams 的计时器每秒发一次 `AXTitleChanged`，WebView 每秒要销毁好几个元素，订阅这些通知会让扫描变成忙循环。

状态机：

```
idle → in_meeting → leave_pending → ended（回到 idle）
                       ↑ 宽限期内重新入会（恢复控件或音频证据）→ in_meeting，沿用原 correlationId
```

- 控件和音频都无法确认时进入 `leave_pending`。超过 `leaveGraceSec`（默认 120 秒）才发出 `ended(detection_timeout)`，时间记为超时发生时刻，另记 `lostAt`。
- **字幕冻结**：会议窗口看不见时，Teams 会暂停它：字幕列表和它自己的计时器都停下，同时显示小窗（小窗的计时器照走）。看不见包括：最小化；在当前没显示的桌面上（例如全屏后切到别的桌面）；被别的窗口完全挡住（推断，见“实测结果”）。程序按“会议窗口最小化 / `unlisted` / 出现小窗”判断，没有弹出的字幕窗口时，持续 `frozenAfterSec`（默认 5 秒）以上提醒一次 `captions.unavailable{window_frozen}`，`cause` 依次是 `minimized`、`off_screen`、`compact_view`。短暂的切换不提醒，例如 ⌘H 后 Teams 自己恢复显示、切 App 时小窗闪一下。
- **页面停走**：会议窗口没被暂停（没有最小化、不是 `unlisted`、没有小窗）时，计时器文本 5 秒没变，说明页面本身停了（`cause: stalled`）。会议窗口被暂停时它自己的计时器也停，所以这时不判断。
- 会议窗口只要还有一部分露在屏幕上，被挡住大部分、别的 App 在前台、焦点在 Teams 主窗口上，都**不会**暂停（实测）。
- 状态存在程序的检查点里：程序重启不会把同一场会议当成新会议。

## 字幕采集（task `captureCaptions`）

- **字幕源**：优先读弹出的字幕窗口（主会议窗口最小化、字幕窗口仍可见时有更新证据），其次读会议窗口里的字幕区。字幕行是 `AXDOMClassList` 含 `fui-ChatMessageCompact__body` 的元素，静态文本依次是发言人和内容，容器就是字幕行的父节点。
- **变化检测**：`captionPollMs`（默认 1 秒）轮询，每次只读容器这一小块子树（最多 400 个节点）。字幕文本变化时 Teams 不发 AX 通知（实测），所以不能靠通知；字幕逐词修订，间隔中位数约 1 秒，1 秒轮询足够拿到每行的最终文本。
- **行的生命周期**：用 `ChromeAXNodeId` 区分行。正在说的行原地修订（实测平均修订 2.4 次，最多 7 次），只保留最新文本和修订次数。满足以下任一条件就定稿：节点消失；同一发言人后面出现了新行；文本稳定超过 `finalizeStableSec`（6 秒）。已定稿的行换 id 重新渲染时，如果在 `rewriteWindowSec`（30 秒）内、同一发言人、文本相同或互为前缀，就视为同一行（实测 20 分钟内出现 8 次）。字幕弹出时同几行会以新 id 出现在新窗口里，也按这条规则合并。
- **时间**：字幕本身不带时间，取采集时刻。
- **缺口**会就地写进记录，例如 `[缺口 10:32–10:35：会议窗口最小化或切到了小窗（compact view），字幕暂停更新；紧接着的几行是恢复后补回的，时间不准，可能不全]`。**不会输出看起来完整的记录。** 缺口的原因：
  - 程序或 helper 重启，续跑时补记；
  - 字幕关闭（5 秒找不到字幕行，字幕面板也不在），也包括模态对话框挡住整个页面的情况；
  - 字幕冻结（会议窗口最小化或出现小窗，持续 5 秒以上）；
  - 页面停走。
- **冻结期间说的话**：会议窗口恢复后，Teams 会把冻结期间的字幕行补出来（实测最小化 40 多秒、说了 3 句，恢复后 3 句都补回）。不过字幕列表最多保留约 26 行，冻结久了、说的话多了，前面的就丢了。
- **任务目录**：`raw.jsonl`（每次变化的增量）、`checkpoint.json`（续跑用）、`gaps.json`、`status.json`；收尾时生成 `record.md`、`record.json`，内容超过 `maxPartBytes` 时另外分片成 `record.partN.md`。
- **结果**：`ok`（没有缺口）、`partial`（有缺口）、`no_captions`（一行也没采到，附原因）。`output` 包含 `recordPath`、`lines`、`speakers`、`durationSec`、`gaps`、`gapSec`。

## 配置（`programs.teams` 或 `/reflex` 下发）

| 键 | 默认 | 说明 |
|---|---|---|
| `scanSec` | 2 | 会议扫描间隔 |
| `leaveGraceSec` | 120 | 离会宽限期 |
| `frozenAfterSec` | 5 | 字幕冻结、页面停走持续多久才算 |
| `captionPollMs` | 1000 | 采集期间的轮询间隔 |
| `finalizeStableSec`、`rewriteWindowSec`、`captionsMissingSec`、`maxPartBytes` | 6、30、5、120000 | |
| `anchorIds`、`clockId`、`captionEntryClass`、`captionPanelIds`、`titleSuffix` | 见 manifest | 选择器；Teams 改版后在这里改 |

## 建议的使用方式

- **最稳妥**：开会时把字幕弹出到单独窗口（字幕区右上角 ⋯ → Open captions in new window）。弹出的窗口浮在最上层，不会被别的窗口挡住，会议窗口最小化时它也照常更新。
- 不弹出的话：让会议窗口**始终有一部分露在屏幕上**。不要最小化，不要被别的窗口整个盖住，全屏时不要切到别的桌面。被挡住一部分、切到别的 App、看 Teams 聊天都没关系。右下角出现小窗，就说明字幕暂停了。
- 多块屏幕：把会议窗口（或弹出的字幕）放到副屏，主屏随便用。程序按窗口读取，不看坐标，窗口在哪块屏上、拖来拖去都能跟上（本机只有内置屏，双屏没实测）。
- 连续约 5 秒窗口被冻结或字幕面板不可读取时，会收到英文提醒：让 Teams 会议窗口或弹出的字幕窗口在屏幕上可见。实际触发时间受 1–2 秒轮询周期影响。每次故障只提醒一次，恢复后再次故障会重新提醒；正常静音且字幕面板仍打开时不提醒。暂停期间的字幕会尽量补回。

## 实测结果（Teams 26246，2026-10-09）

用 Meet now 开了一场只有自己的会议，`say` 外放英文台词，Teams 实时字幕（English）识别：

| 窗口状态 | 字幕是否实时更新 | 台词采到 | 延迟（从开始念到出现） |
|---|---|---|---|
| 会议窗口在前台 | ✅ | 3/3 | 4.0s |
| 别的 App 在前台，会议窗口可见 | ✅ | 3/3 | 3.8s |
| 会议窗口被完全遮住 | ✅ | 3/3 | 4.1s |
| 会议窗口最小化（出现小窗） | ❌ 冻结，恢复后补回 | 3/3 | 38.5s |
| 字幕关闭 | — | 0/2（正确） | — |
| 字幕重新打开 | ✅ | 2/2 | 3.5s |
| 字幕弹出 + 会议窗口最小化 | ✅ | 1/1 | — |

其他发现：

- 计时器：要读 `#call-duration-custom` 里的 `AXStaticText`（每秒更新）；外层 AXTimeGroup 的 title（“Elapsed time 01:18”）基本不更新。
- 字幕关闭时 `captions-panel-dismiss-button` 等面板 id 全部消失，可以据此判断“字幕已关”。
- 所有 AX 节点和通知都属于 Teams 主进程（没有单独的 WebView pid）。
- Settings → Devices → Make a test call 里也有实时字幕，但 test call 大约半分钟就结束，这次它的窗口还卡死了，不适合做探针。

回放测试 `programs/teams/Tests/TeamsTests/RealFixtureTests.swift` 用这次录制裁出的样本（`Fixtures/teams-26246-probe.jsonl`，已伪名化，只保留测试台词）覆盖上述所有状态。

### 2026-10-10：桌面（Space）、⌘H、遮挡

| 窗口状态 | 会议窗口被暂停 | 台词采到 | 延迟 |
|---|---|---|---|
| 会议窗口全屏，然后切到别的桌面 | ❌ 暂停：会议窗口 `unlisted`、出现小窗、它的计时器停住；回来后补回 | 3/3 | 122s |
| 同上，再在桌面 1 点 Teams 主窗口 | ❌ 暂停，回来后补回 | 3/3 | 61s |
| ⌘H 隐藏 Teams | ✅ Teams 约 1.5 秒后自己恢复显示（小窗闪一下） | 3/3 | 12s（中间一次 16 秒的暂停，见下） |
| 会议窗口和主窗口左右并排，焦点在主窗口 | ✅ 不暂停，没有小窗 | — | — |
| 会议窗口被铺满屏幕的 TextEdit 盖住（平铺，边缘和会议窗口对齐） | ✅ 不暂停 | — | — |
| 会议窗口被铺满屏幕的 Teams 主窗口盖住（同上） | ✅ 不暂停（观察 90 秒） | — | — |

- 会议窗口在别的桌面时，用补进来的 `unlisted` 窗口仍然能读到它，所以会议不会被误判结束；离会后它的句柄失效，不会残留。
- **完全遮挡会暂停（推断）**：两次没有最小化、也没切桌面的暂停都发生在会议窗口被更大的窗口整个盖住时。一次是 10-09 第一轮，切到 TextEdit 之后暂停了约 13 分钟；另一次是 10-10 的 16 秒暂停，当时有人点开了一个大窗口。上表里平铺盖住的那几次没有暂停，可能是边缘对齐、圆角处还露着一点。严格对照（会议窗口居中、四周都被盖住）还没做。

回放测试 `SpacesFixtureTests` 用这次录制裁出的 `Fixtures/teams-26246-spaces.jsonl`：会议窗口在别的桌面期间仍是同一场会议，只提醒一次（`cause: off_screen`），离会时间正确；12 句台词各进记录一次，暂停处标了缺口。

## 已知限制

- 字幕是瞬时的：程序重启期间、冻结太久超出字幕列表保留行数的内容补不回来，只能记成缺口。补回的行时间不准。
- 会议窗口里的模态对话框（反馈、设备设置等）会让整个页面从 AX 里消失，期间记为“字幕关闭或不可见”。
- 没实测过的：双屏；弹出的字幕窗口在别的桌面上时是否照常更新；会议窗口被完全遮挡的严格对照。
- 公开 API 拿不到“从没出现在当前桌面上”的窗口（只能拿到焦点 / 主窗口和见过的窗口）。会议窗口通常是在当前桌面上打开的，所以影响不大。
- 拿不到稳定的会议 id：两场同名会议首尾相接（在宽限期内）会被合成一场。
- 组织策略禁止复制字幕时，字幕行可能读不到文本，这时任务返回 `no_captions`。
- 不会自动打开或弹出字幕（v1 只检测并报告）。以后可以加实验动作 `enableCaptions`（⇧⌘A 开关字幕，需要先把会议窗口切到前台，要在 manifest 声明并经你确认）。

## Teams 消息（预留）

`Messages.swift` 里有将来 `teams.message.received` 的 payload 类型和发送防护 `SendGuard`：聊天白名单、发送前核对当前聊天标题和输入框、过滤自己的消息、已发内容哈希（防循环回复）、限速。防护逻辑带单元测试。`draftReply` / `sendReply` 只是桩，**没有**在 v1 的 manifest 里声明。
