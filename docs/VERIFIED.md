# 已验证 / 待实测

环境：macOS 27.0.1 arm64、Swift 6.4 / Xcode 27、Node 24.14.1；DSH 类型基线 0.2.0-rc.2（npm）。日期 2026-10-09、10-10。

## 已验证（自动化测试）

| 范围 | 测试 | 结果 |
|---|---|---|
| 插件规则：校验、静态位置禁止模板、未知 next/root、YAML 错误 | `test/rules.spec.ts` | ✅ |
| 模板：类型保留、路径段清理、`isInside` | `test/rules.spec.ts` | ✅ |
| 程序结果决定是否调 DSH：`ok` → DshBridge 恰好 1 次且文件引用正确；`no_captions` → 0 次；只含 task/run 的规则 → 0 次 | `test/engine.spec.ts` | ✅ |
| 去重：同一 dedupeKey 只有一个 run，重复事件挂到原 run；发件箱重投（同 eventId）只处理一次 | `test/engine.spec.ts` | ✅ |
| stopOn 只停同一 correlationId 的任务；pause 不影响 stopOn | `test/engine.spec.ts` | ✅ |
| 并发三层：每键 drop / queue、每规则 maxRuns；队列在前一个 run 结束后启动 | `test/engine.spec.ts` | ✅ |
| 超时 → stop(timeout) → `timed_out`；取消 → stop(cancel) → `cancelled`；未知 status → failed | `test/engine.spec.ts` | ✅ |
| DSH 重启：run 按 taskId 重新接上，不重复启动任务；先到的结果落盘后续上 | `test/engine.spec.ts` | ✅ |
| prompt 安全：payload 里的“指令”只出现在转义后的数据段；路径注入被清理；允许目录外的文件不交给模型 | `test/engine.spec.ts` | ✅ |
| 外部程序：argv 无 shell、输入输出约定、无 result.json 时按退出码、超时 SIGTERM → SIGKILL 无残留、取消 | `test/external.spec.ts` | ✅ |
| DshBridge（模拟 Agent）：新会话；忙碌时 queue 等**本条**消息被认领再 idle；skip / new-session；超时不取消轮次；会话失效时回退 | `test/bridge.spec.ts` | ✅ |
| leader 锁：只有一个主实例；接管已死或心跳过期的锁 | `test/leader.spec.ts` | ✅ |
| 插件内核 ↔ **真实 Swift helper 进程**：发件箱投递与确认；插件停机期间的事件重启后补发；helper 重启后重连 | `test/integration.spec.ts` | ✅ |
| 插件内核 + 真实 helper + **真实程序子进程**：DSH 停机期间到达的 stopOn 事件仍能停下任务，run 重启后接上并以 `stopOn` 结束 | `test/integration.spec.ts` | ✅ |
| ReflexKit：协议编解码、ULID、manifest 校验、快照哈希、选择器解析、剪枝、伪名化保持前缀；`unlisted` 窗口标记的编解码，旧快照哈希不变 | `swift/Tests/ReflexKitTests` | ✅ 20 项 |
| ReflexKit 护栏：未声明的 App、事件、动作、能力被拒；任务文件不能写出任务目录；动作要确认并有审计 | 同上 | ✅ |
| ReplayAX 与 ProgramHarness：虚拟时间、通知投递、按 Chromium id 解析句柄、任务在停止时间点收尾 | 同上 | ✅ |
| 发件箱：持久化、重载、累计确认、压缩 | `swift/Tests/ReflexHelperCoreTests` | ✅ |
| 程序管理（**真实子进程**）：按需启停；echo 和 stopOn 任务；可续跑任务在程序被 SIGKILL 后从检查点续跑；不可续跑的任务报错；卡死的任务宽限期后被结束（timed_out）；崩溃循环 3 次后停用；循环卡住被检测并重启 | 同上 | ✅ 8 项 |
| teams：会议状态机（宽限期内重连是同一场、超时才结束、App 退出、换会议）；字幕冻结（小窗 / 最小化 / 会议窗口在别的桌面）持续 20 秒才提醒且每段只提醒一次、瞄一眼聊天不提醒、弹出字幕时不提醒、页面停走；标题去掉前后缀；计时器只读内部文本 | `programs/teams/Tests` | ✅ |
| teams：字幕合并（原地修订、消失定稿、换 id 重新渲染、同一发言人的前缀去重只在窗口内、被后续行替代、稳定定稿）、缺口和分片 | 同上 | ✅ |
| teams 回放（合成样本）：started/ended、最小化冻结提醒、重启后不重复 started、采集任务生成带缺口的记录、弹出字幕时最小化不丢字幕、无人说话时 no_captions | 同上 | ✅ |
| teams 回放（**真实录制**，Teams 26246，伪名化、只留测试台词）：前台 / 后台 / 遮挡 / 最小化 / 反馈对话框 / 关开字幕 / 弹出字幕 + 最小化 / 离会。只发一次冻结提醒（cause minimized），离会时间正确；所有测试台词各进记录一次，关字幕时说的不在，缺口标对 | `RealFixtureTests` | ✅ |
| teams 回放（**真实录制 2**）：会议窗口全屏后切到别的桌面（`unlisted`）、再看主窗口、⌘H、离会。会议不被误判结束，只提醒一次（cause off_screen），离会时间正确；12 句台词各进记录一次，暂停处一个缺口 | `SpacesFixtureTests` | ✅ teams 共 29 项（1 项需手动开启） |
| `probe trim`：只留台词行、去掉主窗口标题里的聊天名和其他文字、压缩裁掉的时间；窗口状态识别（含 `unlisted:*`） | `test/probe.spec.ts` | ✅ |
| helper：录制随发起它的客户端断开而停止 | 手动（探针进程被杀后录制曾一直在写） | ✅ 已修 |
| teams 消息预留：SendGuard 白名单、目标核对、防循环、自己消息过滤、限速 | 同上 | ✅ |
| browser：焦点标签事件、快速切换不上报、离开后再回来重新上报 | `programs/browser/Tests` | ✅ |
| CLI：`program new` 生成模板 → `program install` 构建、导出 manifest、lint、安装 | 手动（临时 DSH_HOME） | ✅ |
| helper 空闲占用：CPU ≈0.14%，物理占用 ≈9MB | `dsh-reflex bench` | ✅ 见 PERF |

## 已在本机实测

| 项 | 结果 | 日期 |
|---|---|---|
| **P0 关键假设**：helper（LaunchServices 启动、`DSH Reflex Local Code Signing` 签名）启动的子进程继承辅助功能授权 | ✅ bundle 内和 bundle 外（ad-hoc 签名的独立二进制）的子进程都显示 `trusted`，`responsiblePid` = helper，能读到 Teams 窗口 | 2026-10-09 |
| 用同一身份重建并重装 helper 后，授权仍然有效 | ✅ 新 pid 直接 `trusted`，不需要重新授权 | 2026-10-09 |
| helper 授权后不用重启就能读到新状态（这台机器上 `AXIsProcessTrusted()` 没有缓存旧值） | ✅ | 2026-10-09 |
| Teams 26246 的 WebView 唤醒：`AXEnhancedUserInterface` 和 `AXManualAccessibility` 都返回 unsupported，但树照样被填充 | ✅ 主窗口 1102 个节点，其中 388 个有 DOM id、648 个有 DOM class、1096 个有 `ChromeAXNodeId` | 2026-10-09 |
| WebView 内容属于哪个进程 | 树里所有节点和通知都属于 Teams 主进程（pid 2117），没有单独的 WebView pid | 2026-10-09 |
| **Teams 探针**（Meet now、`say` 外放台词、`probe teams --speak --auto`，由 computer use 操作窗口） | 选择器全部命中（`#hangup-button`、`#call-duration-custom`、`.fui-ChatMessageCompact__body`）。前台 / 后台 / 被完全遮住时字幕都实时更新（3/3，约 4 秒）；会议窗口最小化（出现小窗）时字幕冻结，恢复后补回（3/3，38 秒）；关字幕时面板 id 全部消失；弹出的字幕窗口是浮动的，主窗口最小化时照常更新。字幕文本变化不发 AX 通知 → 改为 1 秒轮询。详见 [TEAMS.md](TEAMS.md#实测结果teams-262462026-10-09) | 2026-10-09 |
| test call 能否开实时字幕 | 能（字幕默认就开着），但 test call 约半分钟结束，这次窗口还卡死了；探针改用 Meet now | 2026-10-09 |
| `AXWindows` 漏掉别的桌面上的窗口 → ReflexKit 补全（`unlisted`） | ✅ 会议窗口全屏后切到别的桌面，它不在 `AXWindows` 里，通过 App 的焦点 / 主窗口和保留的句柄找回，子树照常可读；离会后句柄失效，没有残留 | 2026-10-10 |
| **Teams 探针 2**（`--steps foreground,fullscreen-away,fullscreen-teams,hidden,leave`） | 全屏切到别的桌面：Teams 暂停会议窗口（字幕和它的计时器都停），显示小窗，回来后补回（3/3 + 3/3）。⌘H：Teams 约 1.5 秒后自己恢复显示，字幕照常（3/3）。详见 [TEAMS.md](TEAMS.md#2026-10-10桌面spaceh遮挡) | 2026-10-10 |
| 遮挡对照（静音会议） | 会议窗口和主窗口并排、焦点在主窗口：不暂停；被铺满屏幕的 TextEdit 或 Teams 主窗口盖住（平铺、边缘对齐）：不暂停 | 2026-10-10 |

## 待实测（需要你本机操作）

| 项 | 怎么验证 | 状态 |
|---|---|---|
| 在 Edge 里打开仿 Teams 页面的真实 AX 集成测试 | 给终端授权后：`cd programs/teams && REFLEX_AX_INTEGRATION=1 swift test --filter LiveHTMLTests` | ⏳ |
| Desktop 0.2.0-rc.2 上：新建会话、继续会话、忙碌时排队、取回回复 | 挂载插件后，`dsh-reflex sim` 触发 `dsh` 规则 | ⏳ |
| `reflex-summarizer` 实际带了哪些工具（全局工具会不会被继承，比如 web） | 在它建的会话里查看工具列表 | ⏳ 如果有联网工具，改成 `inlineFiles: true` 并去掉文件工具 |
| 完整闭环：真实会议 → 采集 → 纪要 | INSTALL 第 8 步 | ⏳ |
| 会中、采集中的资源占用 | `dsh-reflex bench` | ⏳ |
| 会议窗口被**完全**遮挡（居中、四周都被盖住）是否暂停 | `probe teams --steps covered-full,leave`，先把会议窗口缩小居中 | ⏳ 目前是根据两次自然发生的暂停推断的 |
| 双屏：会议窗口在副屏、主屏用 Teams 主窗口 | 接上副屏后跑 `probe teams --steps side-by-side,…` | ⏳ |
| 弹出的字幕窗口在别的桌面时是否照常更新 | 同上，加切桌面 | ⏳ |

## 2026-10-29：Teams 音频保活与结束确认（实现验证）

本节记录源码/候选构建验证，不代表已安装到用户正在运行的版本，也不代表已经完成当前 Teams 版本的真实后台实测。CodeGraph 工具在本 session 不可用，按已知文件范围直接阅读与修改。

- `npm run check`：TypeScript 类型检查、60 个测试（11 个文件）及构建通过。新增验证 core 不再注入零秒配置；`user_confirmed`、`detection_timeout` 继续走 stopOn→capture 收尾→summary，重复结束事件/结果不会重复总结。
- `swift test --package-path programs/teams`：44 项，43 通过，1 项按条件跳过。跳过项是需要 `REFLEX_AX_INTEGRATION=1` 和 Accessibility 的 Edge 仿 Teams 页面测试。状态机的可控时间测试、带音频证据的 watch 回放、旧 Teams 真实录制回放和字幕源切换回放通过。
- `swift test --package-path swift`：ReflexKit 21、菜单 UI 2、HelperCore 10，共 33 项通过。包括 ISO-8601 命令编解码、真实测试子进程与 ProgramManager 的命令往返、不可用/失败响应、菜单中英文、倒计时、按钮条件及跨会议快照隔离。
- `swift build --package-path programs/teams -c release`：Teams release 构建通过，程序版本 0.2.3。
- `scripts/build-helper.sh --no-install`：helper/axcheck release 构建、工作区 app 打包与 `DSH Reflex Local Code Signing` 签名验证通过。未执行安装、未向活动 helper 发退出/重启请求。
- 使用 `/tmp/reflex-audio-probe-check` 的临时可执行文件只读查询 CoreAudio 元数据 10 次，全部返回 `inactive`、0 个 Teams 输入进程、无错误；没有读取音频样本。这仅验证当前机器 API 查询无崩溃，并未验证会议内静音/设备切换时的实际输入占用行为。

仍待真实 Teams 验证：入会和挂断、后台/最小化/Space 切换、静音和耳机切换、Teams 音频子进程变化、菜单点击后的实际纪要、全部窗口隐藏与锁屏。独立字幕窗口可见时的旧录制证据和本次回放不能外推为完全后台字幕保证。连续同名会议若没有可观测的结束边界，仍可能合并。

本次没有批量暂存/提交未跟踪文件，没有修改活动采集数据或本机 desired.json。实现设计见 [会议保活与结束确认](superpowers/specs/2026-10-29-meeting-end-confirmation-design.md)。

## 2026-10-29：无预览虚拟扩展屏上的 Teams 字幕（真实短测）

结论：本机短测中，Teams 会议窗口移到没有实体面板、没有预览窗口的虚拟扩展屏后，AX 树仍能读到新增字幕及原句修订。证据来自窗口移回实体屏之前的采样，不能解释为恢复窗口后才补回。此结果支持继续开发虚拟屏方案，不代表长会稳定性或 Reflex 采集/纪要全链路已验证。

- 环境：Apple M4 Pro、macOS 27.2（26B123）、Teams 26276.505.5234.9924；原有内置屏和两块 HP Z34c G3。
- 开源实现：[Display Loom](https://github.com/narumiruna/display-loom/tree/7d537c2)，MIT。Xcode 构建因本机缺失 CoreSimulator 组件而失败；改用 Command Line Tools 的 Swift/Clang 后完整临时 app 编译成功。临时源码关闭自动注册登录项；未安装到 Applications。
- 菜单栏 app 的 CUA 读取超时，因此实际显示器测试使用单独的 Objective-C 驱动程序，链接该提交原有的 `VSCGVirtualDisplayBridge.m`。创建 1920×1080、60 Hz 的 `Reflex Caption Test`，不启动预览、录屏或流媒体；设置 15 分钟退出上限及主动停止文件。测试范围是 Display Loom 的底层显示器实现，不是发行版 app 的完整集成测试。
- 通过 Teams 日历的即时会议创建单人测试，未邀请他人，摄像头关闭，Plantronics Blackwire 5220 Series 麦克风开启；字幕语言为简体中文。用户发声提供测试输入。
- CUA 使用 Teams 的 Window → Move to Reflex Caption Test 移动会议窗口；再次打开菜单，出现 Move to Built-in Retina Display 而不再出现 Move to Reflex Caption Test，确认窗口所在显示器已改变。字幕采样期间没有把窗口移回实体屏，也没有开启虚拟屏预览。

| 时间（Asia/Shanghai） | 状态 | 观测 |
|---|---|---|
| 14:32:37 | 实体屏基线 | AX 字幕文本 16 字符 |
| 14:33:16 | 虚拟屏 | AX 字幕文本 71 字符，已含移屏后的测试发言 |
| 14:33:51 | 虚拟屏 | AX 字幕文本 89 字符，出现修订及新增发言 |
| 14:34:24 | 虚拟屏 | 文本仍为 89 字符；会议计时内部文本继续更新到 03:53 |

字符数包含 AX 返回的说话人标签，仅用于说明文本变化；不在本记录转储字幕正文。采样间隔约 35 秒，未测量端到端字幕延迟；也未独立记录每个采样时的前台进程。不是持续讲话的长时间压力测试。

清理完成：先将会议移回内置屏，再离开单人测试会议；停止探针，确认活动显示器从 4 个恢复为原来的 3 个，原显示器 ID、位置、尺寸及非镜像状态与测试前一致。临时程序已退出，没有注册登录项，没有更新活动 Reflex 安装或配置。

原始显示器元数据：`/tmp/reflex-virtual-display-research/probe.jsonl`；临时构建与探针源码保存在同目录的 `display-loom/.manual-build/`。后续仍需验证长会、静音、独立字幕窗口、最小化/⌘H、Space 切换、锁屏/睡眠、显示器断开恢复，以及 Reflex 实际采集和纪要流程。不可把“在虚拟屏上展开的窗口”外推为这些状态均可持续采集。

## 2026-10-29：左上角后台屏幕与状态栏移入/带回（候选实现）

- 实现了纯窗口移入/带回，没有屏幕捕捉或预览。左上角算法、窗口/显示器所有权、失败后恢复、同一窗口手动移出后清理、关闭窗口、显示器变化和 helper 退出处理均已接入。设计与限制见 [后台屏幕](superpowers/specs/2026-10-29-teams-background-display.md)。
- `swift test --package-path swift`：43 项，42 通过，1 项真实显示器测试按环境变量跳过。ReflexKit 21、Helper UI 3、HelperCore 19（含 9 个新增后台屏幕测试）。中英文按钮、没有活动会议时仍可带回、重复/过期操作、恢复失败保留屏幕、AX 未知不销毁、拓扑变化等通过。
- `REFLEX_DISPLAY_INTEGRATION=1 swift test --package-path swift --filter BackgroundMeetingTests`：9 项全部通过，其中真实测试创建并关闭了 1920×1080 虚拟屏。请求 `(-3559,-2520)`，macOS 返回 `(-3560,-2520)`，与左上方 HP 屏的角点相接。原有三块屏幕的 ID/位置/尺寸创建前后均保持一致，释放后活动显示器列表也完全恢复。
- 初次真实测试发现系统会吸附 1px 且注销显示器异步完成；已增加安全吸附容差和等待注销处理后复测通过。容差仍要求原屏幕布局不变、无面积重叠，不能默默接受普通并排位置。
- `scripts/build-helper.sh --no-install`：release 构建、helper/axcheck 打包以及 `DSH Reflex Local Code Signing` 签名验证通过。MIT 许可证随 bundle 打包。日志在 `/tmp/reflex-background-{swift-tests,display-live,helper-build}.log`。
- 未更新活动安装、未变更 desired.json、未批量暂存/提交。新状态栏按钮与新 AX 几何移动尚未在真实 Teams 上联调；前一节的成功证据是通过系统 Window 菜单进行的短测，不能替代新按钮的验证。鼠标误入概率是否足够低仍需要日常操作检验，本实现不拦截鼠标。

## 2026-10-29：状态栏面板精简（候选实现）

移除面板右上角状态文字/圆点、重复的 Reflex 标题栏、Open DSH 底栏及常驻操作说明（改为悬停提示）。标题只展示当前会议；idle/suppressed/程序停止时显示“当前没有会议”，不会回退到上一场 run.title。Transcript 按当前会议 correlationId 隔离，面板宽度 480、正文 15pt、滚动区高度 380，展示最近 30 条。

`swift test --package-path swift --filter MenuPanelTests`：3 项通过，覆盖标题/字幕跨会议隔离、结束后清空、等待确认保留当前标题、语言及菜单布局。`scripts/build-helper.sh --no-install`：release 构建与本机身份签名验证通过。日志：`/tmp/reflex-menu-cleanup-{tests,build}.log`。未替换活动安装。

## 2026-10-29：安装到本机运行版本

用户授权替换后，确认运行中的 run 为 0、outbox 待确认事件为 0，再通过 `dsh-reflex helper install` 安装 helper 和内置程序。新 helper pid 92683，Teams pid 92766，DSH 已自动重连，Teams 状态 idle。**更正：当时状态报告中的 0.2.3 是安装 manifest 版本；后查 ready 日志，pid 92766 实际仍运行 0.2.2。先前据此判断更新成功不成立。** 安装文件与候选 helper 的 SHA-256 一致，原 desired.json 配置语义保持一致。辅助功能与 bundle 内/外子进程授权 selftest 均通过。未覆盖采集数据。旧版备份：`/Users/i060912/.dsh/reflex/backups/update-20261029-151041`。安装日志：`/tmp/reflex-install-20261029.log`。CUA 对菜单栏常驻进程读取超时，未完成实际弹出面板的视觉核对；新按钮的真实会议联调仍待执行。

## 2026-10-29 16:10：修复按钮和字幕消失的安装回归

根因：helper 重启后 DSH 立即重连，在新 Teams 可执行文件复制前启动了旧的 0.2.2；rescan 只更新 manifest，没有重载进程。旧进程不发布 correlationId/commandsSupported，因此菜单隐藏后台按钮及字幕。另外 taskList 漏传 correlationId，与仍运行旧 TS 插件的 desktop.status 组合时，即使更新 Teams 也无法匹配字幕。

- ProgramManager 对已安装可执行文件计算 SHA-256，字节变化时优雅重载并续接 resumable 任务；存在不可恢复任务则延后。重复扫描相同文件不重启。状态报告区分 ready 握手版本与 installedVersion。
- taskList 只额外公开 correlationId，不公开完整 input；菜单与 checkpoint 选择优先使用这一字段，保持会议隔离。
- helper 安装先复制并验证完整签名 bundle，再发布到安装路径，最后停止旧 helper，防止 DSH 重连启动旧 bundle。
- 增加已认证本地 RPC `helper.menuStatus`，走菜单实际选择链路，只返回 ID、字幕条数和状态，不返回字幕正文。
- 全量 Swift helper 测试 44 项，43 通过、1 项真实显示器测试未启用；Teams 45 项，44 通过、1 项网页 AX 集成测试未启用。新增真实 executable 替换/同任务恢复/版本报告、真实 taskList 字段匹配和旧 tracker 存档迁移回归。最后修改后重跑相关 13 项全部通过。release 构建、本机身份签名验证和安装后子进程辅助功能 selftest 均通过。未修改 TypeScript，此次未重跑 TS 测试。
- 在真实会议中更新：helper pid 42521、Teams pid 42531，ready/运行状态均为 0.2.3。保留原 correlation `teams:62846f5afd:1793260837` 和 task `01M63ASQ144Z9MNR4F18HN0M7N.capture`，deliveries 从 1 变为 2；outbox lastSeq 保持 46，没有额外开始/结束事件。菜单实际选择到同一任务的 53 条字幕，openGap=null，会议状态 in_meeting，音频 running，deadline=null。
- 部署前备份：`~/.dsh/reflex/backups/live-menu-deploy-20261029-160910`。日志：`/tmp/reflex-menu-fix-{swift-tests,teams-tests,final-tests,build,install,selftest}.log`。不提交全项目，不恢复覆盖活动 checkpoint。

用户随后确认“有按钮和字幕”，并说明误点了结束按钮。此后的 suppressed 状态、task 结束以及 lastSeq 48 来自这次用户手动结束，不能算作升级拆会。CUA 仍无法读取菜单栏常驻窗口；本次没有操作真实会议来测试移入/带回按钮，也没有挂断 Teams。

## 2026-10-29 16:17：重新接入与玻璃面板

- 用户要求接入误停止记录后的当前会议并改善 UI。Teams 0.2.4 增加 `attach`：从 suppressed 显式接入，校验旧目标和当次扫描的真实会议控件；音频单独保活不能开启新采集。新记录使用独立 correlationId，即使同一秒结束/接入也不复用 dedupe key；命令回执和 pending event 沿用持久化防重。过期、重复、旧按钮和失败扫描均有测试。
- 面板使用 macOS 26+ 原生 Liquid Glass 背景，旧系统用 ultraThinMaterial；500pt 宽，400pt 字幕区。背景材质与正文分层，正文保持系统前景色。移入/带回是主要按钮；结束操作独立置底并确认，取消不发送命令。“采集当前会议”入口说明新记录保留旧记录。
- Teams 全量 47 项，46 通过、1 项网页 AX 集成未启用；UI 5 项通过。生成中英、明暗、采集/确认/停止共 12 张合成数据布局图，检查文案与可读性。离屏位图不能证明实际桌面背景折射效果；实际材质交由系统 compositor。原图 `/tmp/reflex-glass-preview/`，无真实字幕内容。
- release 构建、本机签名和安装通过。程序安装触发真实 SHA-256 重载：旧 pid 42531 → 49466，ready 0.2.4，保持 suppressed，无自动 started。通过同一 `programs.command` 链路发送一次 attach，得到新 correlation `teams:62846f5afd:1793261767:manual:107a8111aa6b352f`、新任务 `01M63BP2HQ2CQNWD1NBQ0Y5FZN.capture`；菜单读到 27 条字幕，openGap=null，lastSeq 49。旧 run 未修改，停止期间 UI 已消失的字幕无法补采。
- 最后 helper 更新续接这段新记录；以 `helper.menuStatus`、运行版本、任务 ID 和 outbox 序号核对，不仅检查 manifest。日志 `/tmp/reflex-{reattach,glass}-*.log`。用户已确认前一修复版按钮和字幕出现；新移屏按钮的真实移入/带回往返仍未在本次真实会议中操作。

## 2026-10-29 16:35：字幕停在旧文字

用户明确报告 Teams 出现新文字，Reflex 仍停在旧文字。初次检查 checkpoint 只有约 13 KB、44 条；savedAt 正常刷新，但末尾 lastChanged 停在 08:25 UTC。不能把持续保存文件当作文字仍同步的证据。

- 修复两个读取缺陷：原先从列表前端读取，400 节点预算会在长列表中被旧行占满；旧字幕容器只要还能读取就被永久复用，即使已被 Teams 的新容器替换。新 ReadLimits.tailFirst 优先尾部、返回原文档顺序，LiveAX/ReplayAX 一致，旧 fixture 缺字段仍兼容。每 2 秒重新从会议/字幕窗口定位容器。截断的单条字幕不作为完整行接收。
- 新回归用 500 条字幕复现预算耗尽，验证预算仍为 400 时能拿到最新行及后续新行、保留说话人与正文顺序、正确的 replay ref 路径。另一个场景保留仍可读的旧列表句柄，验证定期定位会切换至当前会议列表。
- 文字变化立即保存，菜单刷新改为 common run-loop modes 下 0.5 秒，布局后跟随滚动。未删除历史字幕，也未缩减完整记录。
- 现场换新进程后的首个诊断读取只有 101 个节点、24 行，head/tail 没有差异。因此长列表上限是已复现的代码缺陷，但该现场采样不能单独证明这次停更正由截断触发。进程重新定位后立即读取了新字幕，随后记录由 123 增至 131 条；用户最终明确确认“能跟上了”。不宣称测得端到端延迟。
- Teams 0.2.6 全量 49 项：48 通过、1 项可选网页 AX 集成跳过；helper/ReflexKit/UI 共 46 项：45 通过、1 项可选显示器集成跳过。release 构建、本机签名、安装和辅助功能 selftest 通过。TS 未修改，未重跑。日志 `/tmp/reflex-caption-sync-*.log`。
- 原 task `01M63BP2HQ2CQNWD1NBQ0Y5FZN.capture` 与 correlation `teams:62846f5afd:1793261767:manual:107a8111aa6b352f` 保持，更新用 resumable 续接。部署前备份 `~/.dsh/reflex/backups/caption-sync-20261029-163058`。新增诊断只含节点数、省略数、行数和末行是否一致，不转储字幕正文。

## 2026-10-29 16:54：采集统计与参会名单

- 菜单显示本段采集开始时间、时长、完整字幕条数及参会人展开区。开始时间优先使用 capture checkpoint.startedAt，fallback 为原任务 startedAt，不能取 Teams 会议开始时间或 helper 重启时间。整段 75 条的用例验证正文只展示 30 条但统计仍为 75；跨天、本地时区、超过一小时、时间倒拨、旧会议数据隔离及中英文通过。
- 参会名单以 15 秒周期读取会议窗口的 AXOutline/Attendees 当前参会分组，保存全部已见姓名及名单变化快照；不把邀请或仅加入聊天的成员纳入名单。重复显示名按观测中的最大出现次数保留，不推断稳定身份。部分/关闭/错误状态不清空已见姓名，不生成虚假离会。名单进入 record.md/record.json，JSON 时间使用 ISO-8601。日志只记状态、读取人数和界面人数。
- Teams 测试 53 项，52 通过、1 项可选网页 AX 测试未启用；菜单相关 6 项通过。包括旧 checkpoint 缺 participants 兼容、名单持久化、部分名单、邀请排除、See more 行排除、原生树标题与描述分别匹配、最终 Markdown/JSON 输出。中英明暗布局已渲染检查。release 构建与本机签名通过，安装 Teams 0.2.8 和新版 helper。日志 `/tmp/reflex-{participants,capture-info}-*.log`。
- 现场边界：CUA 在本轮读取到 Teams 显示 31 人的面板，但 16:44:28 窗口锚点与音频同时消失，16:46:30 以 detection_timeout 正常结束；新名单代码 16:45 才开始运行，因此不能声称自动名单采集已在这场真实会议验证成功。实时名单读不到是会议窗口已结束，并非已证实的 selector 故障。源实现和 replay 测试后续仍需真实会议检验。
- 从本轮已读取的 Teams AX 快照恢复 20 个已展开的实际参会姓名，另外 11 人藏于 See more，无法会后补采。剔除了 Others invited/People added to the chat。用 `participants-supplement.json` 明确 recoveredAt/恢复来源，observedAt=null（没有保存精确观测时间），补入这场 capture/record.md 与 record.json 的 recoveredSnapshot，不编造名单时间线。修改前的两份原文件备份于 `~/.dsh/reflex/backups/participant-supplement-20261029-165248`。
- 本段记录为北京时间 16:16:07–16:46:30、182 条字幕。原 summarize 步骤已有“模型返回了不在本次候选范围内的会议片段”错误，名单补充没有重写或重跑纪要；本次任务未处理该独立问题。没有创建新会议或向他人发送信息。

## 2026-10-29：空闲菜单视觉调整

原先仅显示 No current meeting 的空白面板改成居中待机卡片：淡色圆形波形图标、下一场会议标题和开启 Teams 字幕的两行提示，沿用原生玻璃背景。离线、未授权、监测暂停、安装缺失或失败显示对应文案，不能误标为就绪。保留后台窗口恢复入口、重新采集入口及已有错误提示；不改会议检测或字幕逻辑。

菜单相关 6 项测试通过，扩展现有渲染夹具检查中英/明暗的空闲与离线状态，宽度保持 500pt。合成预览 `/tmp/reflex-idle-preview/`，日志 `/tmp/reflex-idle-{tests,build,install}.log`。release 构建与签名检查通过；安装前无活动采集任务。实际系统玻璃折射效果未通过 CUA 截图核对。
