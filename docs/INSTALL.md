# 安装与实测

环境：macOS 13+（开发机为 27.0.1 arm64）、Xcode / Swift 6、Node 22.19+，DSH `>=0.2.0-rc.2 <0.3.0`。

## 从 DSH 安装（推荐）

在 Desktop 的 Plugins 页面添加并启用 `@sincerity711/dsh-reflex`。插件加载后会弹出安装引导，点击安装助手、确认 macOS 签名提示，然后打开辅助功能设置并授权。无需运行下面的开发命令。界面可查看编译日志并重试；“稍后设置”后可从插件页的“安装与权限”继续。

若 npm 尚未上线，在 Plugins 页面使用 GitHub Release 的 `.tgz` 下载 URL。macOS 13+、Swift 6 是前提；缺少工具时系统会弹出安装提示。首次安装会复制默认 Teams 规则，不覆盖已有规则。安装不自动启用 Teams 监听，请配置场景后用 `/reflex program enable teams` 确认启用。

以下步骤用于源码开发和手动排查。

## 1. 构建

```bash
cd ~/SAPDevelop/dsh-reflex
npm install && npm run build
```

`npm install` 的 `prepare` 会编译到 `lib/`。CLI 入口是 `node lib/cli/dsh-reflex.js`；`npm link` 后也可以直接用 `dsh-reflex`。下文都写成 `dsh-reflex`。

## 2. 签名身份（只需一次）

```bash
./scripts/setup-local-signing.sh
```

它会在登录钥匙串里创建并信任自签名身份 `DSH Reflex Local Code Signing`，过程中要输入一次登录密码。之后 helper 每次重建都用这个身份签名，TCC 授权一直有效。没有这个身份时会退回 ad-hoc 签名，状态里会提示：每次重建都要重新授权。

## 3. 安装 helper 和内置程序

```bash
dsh-reflex helper install
```

执行内容：

1. 编译 Swift 包（release）；
2. 打包并签名 `DSH Reflex Helper.app`，安装到 `$DSH_HOME/reflex/helper/`；
3. 编译、安装 `programs/teams` 和 `programs/browser`。程序装好后默认**不启用**。

## 4. 授权与自检

```bash
dsh-reflex helper start
dsh-reflex helper access      # 在“系统设置 → 隐私与安全性 → 辅助功能”里打开 DSH Reflex Helper
dsh-reflex selftest
```

授权后 helper 会自动重启，让新的授权生效（授权状态在进程内有缓存）。`selftest` 应该显示：

- helper 已授权；
- 两个子进程（一个在 bundle 内，一个是 `programs/_axcheck` 下的独立二进制）都“继承成功”，且“TCC 归属 helper”。

如果子进程没有继承授权，程序就要改为编进 helper 同一进程（见 PLAN 的 P0 决策门），请把输出发回。

## 5. 挂载到 DSH

**Desktop**（profile `desktop`）：先完全退出 Desktop，然后执行

```bash
"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh" plugin --profile desktop add link:$HOME/SAPDevelop/dsh-reflex
```

再打开 Desktop。

**dsh web**：`dsh plugin add link:$HOME/SAPDevelop/dsh-reflex`。

两者同时挂载时，只有一个是主实例，另一个在 `/reflex status` 里显示“被动”。

插件 bundle 会插入两行：`dsh-reflex` 本身，以及 agent preset `reflex-summarizer`（只读文件 + 搜索，无 shell、无 web）。插件配置（可在 DSH 的插件设置里改）：`autoLaunchHelper`、`helperIdleExitSec`、`rulesFile`、`workspacePath`、`allowedFileRoots`、`stopGraceSec`、`defaultTaskTimeout`、`defaultRunTimeout`、`defaultDshTimeout`、`retentionDays`、`programs`（各程序的配置覆盖，如 `{ teams: { leaveGraceSec: 180 } }`）。

Teams 场景的 setup 可保存自动总结模型、工作目录、提示词、回看分钟数和会议归档绝对目录。选定模型持久化为 `teams-settings.json` 的 `model: { provider, model }`；自动会话显式传递该选择，不修改 DSH 默认模型。`archiveDirectory` 留空关闭归档；Obsidian vault 可设为 `<vault>/02_Sources/Meetings`。原文复制和归档由插件执行，summarizer 继续保持只读；`transcript.md` 不经模型生成。`prompts/obsidian-meeting-summary.md` 是可使用的示例。

## 6. 规则

```bash
mkdir -p ~/.dsh/reflex && cp examples/rules/teams-meeting-summary.yaml ~/.dsh/reflex/rules.yaml
dsh-reflex rules validate
```

在 DSH 中执行 `/reflex status`，确认规则显示“2 条有效”，helper 已连接、已授权。

## 7. Teams 探针（Teams 升级后重跑）

```bash
dsh-reflex dev on
dsh-reflex probe teams --speak
```

用日历里的 **Meet now** 开一场只有自己的会议，打开实时字幕（⋯ → 语言和语音 → 打开实时字幕），字幕的口语语言设为 English。Settings → Devices → Make a test call 也有字幕，但大约半分钟就结束，不够用。`--speak` 会在每一步用 `say` 外放念 2–3 句英文台词（请用外放，不要戴耳机），报告逐句核对哪些进了字幕。之后按提示依次操作：前台、后台、完全遮挡、并排（焦点在主窗口）、铺满遮挡、最小化、弹出字幕、遮住主窗口保留弹出字幕、关闭和打开字幕、断网重连（可跳过）、全屏后切桌面、全屏时看主窗口、⌘H 隐藏、挂断。每一步录制 20 秒。`--steps a,b,…` 只跑其中几步；`--auto` 改为由 `<输出目录>/next` 文件推进，用于脚本或 agent 操作 Teams。

输出在 `~/.dsh/reflex/data/probes/<时间>/`：

- `probe-report.md` / `.json`：选择器、通知类型和发通知的 pid、各步骤的窗口状态（最小化 / 小窗 / 弹出字幕）、字幕是否更新、台词采到几句、修订方式；
- `teams-probe.jsonl`：已伪名化的录制，但仍包含会议期间其他人说话的（伪名化）文字。用 `dsh-reflex probe trim <录制> --out programs/teams/Fixtures/<名字>.jsonl --script-only --range a-b …` 裁成只含测试台词的回放样本后再提交；
- `inspect-initial.json`：初始 UI 树。

**决策门**：报告里如果没有字幕条目（`fui-ChatMessageCompact__body`），先停下来确认替代方案。2026-10-09 在 Teams 26246 上已通过。

## 8. 启用 teams，跑完整闭环

在 DSH 中：

```
/reflex program enable teams
/reflex program enable teams --confirm <确认码>
```

开一场真实会议，建议把字幕弹出到单独窗口（字幕区 ⋯ → Open captions in new window），这样会议窗口最小化、被挡住时也不会漏字幕。不弹出的话，让会议窗口始终有一部分露在屏幕上（不要最小化、不要整个盖住、全屏时不要切到别的桌面）；有两块屏幕时把会议窗口放到副屏最省心。`/reflex status` 应该依次看到：teams 程序运行、会议进入 `in_meeting`、run 进入 `capture`。挂断后（默认宽限 120 秒）任务收尾，DSH 里出现一个“会议纪要 · <会议名>”会话。纪要同时写入 `~/.dsh/reflex/data/runs/<runId>/summary.md`，字幕记录在 `…/capture/record.md`。

## 常用命令

```bash
dsh-reflex status                 # 插件状态（通过控制 socket；插件不在时退回 helper 状态）
dsh-reflex helper status          # helper 状态
dsh-reflex runs / run <id> / cancel <id>
dsh-reflex sim teams.meeting.started --correlation m1 --payload '{"title":"Test"}'   # 需要 dev on
dsh-reflex pause [--all] / resume
dsh-reflex bench --duration 60s --label "会中采集" --out docs/PERF.md
```

## 卸载

```bash
dsh-reflex helper stop
rm -rf ~/.dsh/reflex          # 会删除规则、记录和纪要，请先备份
```

最后在系统设置里删除辅助功能条目，并在 DSH 里移除插件。
