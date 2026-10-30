# dsh-reflex

把 macOS 上发生的 UI 事件按规则转成动作：只执行程序、直接调用 DSH，或先执行程序、再根据结果决定是否调用 DSH。长时间的监听和采集由原生小程序负责，只有需要理解、决策或总结时才调用模型。

v1 的完整场景是 Teams 会议：识别会议开始 → 采集实时字幕 → 会后整理成记录 → 交给 DSH 写纪要。

```
Teams / 浏览器 …（Accessibility）
        │
DSH Reflex Helper.app ── 持有辅助功能授权，按需启动程序（teams、browser、你写的程序）
        │  unix socket · JSON-RPC · 发件箱（断线补发）
dsh-reflex 插件（DSH 内）── 规则 → 调度：task（程序任务）/ run（本机程序）/ dsh（会话）
```

## 组成

| 部分 | 位置 | 说明 |
|---|---|---|
| helper | `swift/Sources/ReflexHelper*` | 独立签名的 LSUIElement App。程序管理、心跳、崩溃重启、发件箱、开发工具 |
| ReflexKit | `swift/Sources/ReflexKit` | 写程序用的 Swift 库：AX 读取/观察/唤醒、事件与任务、检查点、`ReplayAX` 回放测试 |
| teams 程序 | `programs/teams` | 会议识别状态机、实时字幕采集与整理 |
| browser 程序 | `programs/browser` | 浏览器当前标签页标题事件（按 AI 编写流程写成） |
| DSH 插件 | `src/` | supervisor、事件总线、规则、调度、DshBridge、`/reflex` 命令、leader 锁 |
| CLI | `dsh-reflex`（`lib/cli/dsh-reflex.js`） | helper 安装与状态、`ax inspect/record`、探针、程序开发、模拟事件、bench |

## 在 DSH 中安装

在 DSH Desktop 的 Plugins 页面添加 `@sincerity711/dsh-reflex` 并启用。首次加载会自动弹出安装引导：点击 **安装本机助手**，按系统提示确认本机签名，再点击 **打开辅助功能设置** 授权。需要 macOS 13+ 和 Swift 6；缺少开发工具时会打开系统安装提示。安装保留已有规则与会议记录。

之后在插件页面配置 Teams 场景，通过 `/reflex program enable teams` 按提示确认启用监听。可选择“稍后设置”，再从插件页面的 **安装与权限** 继续。

尚未发布到 npm 时，可在 Plugins 页面添加 [GitHub Release](https://github.com/sincerity711/dsh-reflex/releases/latest) 中 `.tgz` 资产的下载 URL，安装引导相同。

构建和发布说明见 [docs/RELEASING.md](docs/RELEASING.md)。

## 本地开发

详细步骤见 [docs/INSTALL.md](docs/INSTALL.md)。

```bash
npm install && npm run build
./scripts/setup-local-signing.sh            # 只需一次，会要求输入登录密码
node lib/cli/dsh-reflex.js helper install   # 编译、签名、安装 helper 和内置程序
node lib/cli/dsh-reflex.js helper access    # 在系统设置里打开 DSH Reflex Helper
node lib/cli/dsh-reflex.js selftest         # 验证程序子进程能用 helper 的授权
```

然后在 DSH 中挂载插件、写规则（[examples/rules](examples/rules)），用 `/reflex status` 查看状态，`/reflex program enable teams` 启用 teams 程序。

## 文档

- [ARCHITECTURE](docs/ARCHITECTURE.md)：进程模型、数据流、安全边界
- [PROTOCOL](docs/PROTOCOL.md)：插件 ↔ helper、helper ↔ 程序的消息格式与文件布局
- [RULES](docs/RULES.md)：`rules.yaml` 参考
- [AUTHORING](docs/AUTHORING.md)：用 ReflexKit 写一个新程序（给 AI 和人看的流程）
- [TEAMS](docs/TEAMS.md)：teams 程序的行为、配置与限制
- [INSTALL](docs/INSTALL.md)：Mac 上的安装与实测步骤
- [PERF](docs/PERF.md)：资源占用实测
- [VERIFIED](docs/VERIFIED.md)：已验证的能力、版本与仍待实测的部分
- [PLAN](docs/PLAN.md)：设计与实施方案

## 测试

```bash
npm test                                   # 插件（含与真实 helper 进程的集成测试）
cd swift && swift test                     # ReflexKit + helper（程序托管用真实子进程）
cd programs/teams && swift test            # teams 状态机、字幕合并、回放
cd programs/browser && swift test
```

兼容 DSH `>=0.2.0-rc.2 <0.3.0`，仅 macOS。MIT。

### Desktop 场景设置与会议记录

在 Desktop 的 **Plugins → dsh-reflex → 配置与执行记录** 中，选择 Teams 会议，可设置总结提示词、DSH 会话工作目录和同名会议回看时间（默认 5 分钟，0 表示关闭）。保存只影响该场景，不改写 `rules.yaml`。在执行记录中可查看字幕、采集缺口、发送给 DSH 的提示词、纪要和原始日志。设置存放在 `$DSH_HOME/reflex/state/teams-settings.json`，执行记录遵循插件的保留期限。

setup 还可选择自动任务的模型和会议归档目录。保存的 provider/model 用于此后的自动总结，不受 DSH 全局默认模型切换影响；升级前未选择模型的配置仍使用默认模型。归档目录留空时关闭归档；启用后由插件代码保存会议入口、`ai-summary.md` 和 `transcript.md`，原始采集文件保存在归档目录的 `_reflex-captures/<runId>/` 中，不随 Reflex 运行记录过期删除。模型始终只读，只生成纪要和要合并的候选 runId；程序复制完整原文、按时间拼接并以 runId 去重。确认连续的会议更新同一归档，同名独立会议或已有 Teams recap 会使用独立文件名。模型或归档失败会显示在执行记录，模型失败前已复制的原始字幕仍保留。Obsidian 提示词范例见 `prompts/obsidian-meeting-summary.md`，日期以 Asia/Shanghai 计算。

Teams 程序启用后，检测到会议开始时启动字幕采集并发送本机通知；检测到离会时立即收尾，字幕可用时交给 DSH 总结。实际延迟取决于 Teams 窗口检测、采集收尾和模型响应。近期同名会议的记录只是提供给模型的参考，由模型判断是否合并；每次原始运行仍独立保存。Teams 字幕需要开启，识别可能有误。零等待意味着短暂的窗口检测丢失也可能被视为离会；如有需要，可通过插件的 `programs.teams.leaveGraceSec` 配置调整。

Teams 窗口冻结或字幕面板不可读取连续约 5 秒后，Reflex 会发送英文通知，提醒让会议窗口或弹出的字幕窗口在屏幕上可见。每次故障只提醒一次，恢复后再次故障会重新提醒；正常静音不触发。可用 `programs.teams.frozenAfterSec` 和 `captionsMissingSec` 调整阈值，实际提醒时间受轮询周期影响。

macOS 菜单栏的 Reflex 波形图标可展开状态面板，查看当前会议、最近字幕和总结状态；面板收起不影响采集。正常退出 DSH 时 Helper 和采集任务停止，已写入的数据保留，中断的任务不会自动生成纪要；仅关闭 DSH 窗口而不退出应用时继续运行。面板中的“打开 DSH”唤醒 DSH，具体记录可从插件页面打开。
