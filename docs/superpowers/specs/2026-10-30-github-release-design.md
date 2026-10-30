# GitHub、npm 发布与单命令安装

公开仓库为 sincerity711/dsh-reflex，npm 包为 @sincerity711/dsh-reflex；无 scope 的名称已被其他维护者占用。保留 CLI、状态目录和插件 ID dsh-reflex，bundle 加载名称使用 scoped 包名。

push/PR 在 macOS 上执行 Swift 测试、构建 helper、TypeScript 检查与测试，打包并验证 npm tarball。v* 标签检查版本一致后创建 GitHub Release 并附上 tarball。独立 npm 发布工作流支持 Trusted Publishing 或 NPM_TOKEN；首次发布需要 npm 账号授权，不能用 GitHub 登录替代。

插件客户端加载后自动检查安装状态，缺少助手或已明确未授权时弹出原生 dialog 安装引导。用户点击才创建本机签名、编译助手和内置程序；服务端运行受限安装步骤并提供进度与错误，失败可重试。缺少 Swift 6 时打开系统开发工具安装提示。首次复制规则且不覆盖既有规则，安装后唤醒 supervisor，按钮打开系统辅助功能设置；权限生效后显示完成。可稍后设置，服务端持久化跳过状态，插件页提供重新打开入口。启用 Teams 保留现有访问确认流程。Swift 源码、测试目标和第三方许可证随包发布。无需额外终端安装命令。

用户已确认公开仓库及 Actions/npm 发布方案，并要求单命令安装。验证包括现有测试、安装编排的失败与规则保留测试、真实 npm tarball 内容检查以及 GitHub Actions 运行。
