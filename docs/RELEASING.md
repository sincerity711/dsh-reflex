# 构建与发布

仓库：https://github.com/sincerity711/dsh-reflex
npm 包：`@sincerity711/dsh-reflex`（无 scope 的名称属于其他维护者）。

## GitHub Actions

- push 到 main、PR 或手动运行 Build and release：macOS 15 + Node 24，测试 Swift 三个包，构建 helper，执行 TypeScript 检查、插件/进程集成测试，再生成和验证 npm tarball，上传 Actions artifact。
- 推送 `v<package.json.version>` 标签：检查版本一致，然后附上相同 tarball 到 GitHub Release。包携带编译后的 JavaScript、DSH 元数据及 Swift 源码；在用户本机创建签名并编译助手。
- npm 发布使用单独的 Publish npm package 工作流，可手动指定已构建完成的 release 标签。启用仓库变量 `NPM_PUBLISH_ENABLED=true` 后，标签发布流程会接着调用 npm 工作流。

## npm 首次配置

GitHub 凭据无法代替 npm 账号授权。首次发布可以在仓库 `npm` environment 配置允许发布该 scope 的 `NPM_TOKEN`，再手动运行 Publish npm package（version: v0.1.0）。也可以由有权限的 npm 维护者下载 release tarball，执行 `npm publish <tarball> --access public`。

包创建后，推荐在 npm 包设置的 Trusted Publisher 中配置：

- Provider: GitHub Actions
- Organization or user: sincerity711
- Repository: dsh-reflex
- Workflow filename: publish.yml
- Environment: npm

然后设置仓库变量 `NPM_PUBLISH_ENABLED=true`。Trusted Publishing 不需要长期 token，配置完成可移除 NPM_TOKEN。Actions 使用 Node 24 自带的现代 npm，申请 OIDC 凭据并附带 provenance。

## 后续发布

更新 package.json 和 package-lock.json 中的版本，提交后推送 main，再推送对应标签：

```sh
git tag v0.1.1
git push origin v0.1.1
```

npm 版本不可覆盖；重试前确认该版本是否已发布。构建失败不会产生 release。GitHub Release 可用 `.tgz` URL 直接作为 DSH 插件来源，即使 npm 尚未配置也能安装。
