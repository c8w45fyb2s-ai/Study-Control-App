# 贡献指南

感谢你愿意改进 Study-Control-App。
毕竟是新手的第一份练习项目，所以以下也都是ai出来的内容，有何错误请多多指出与批评

## 开始之前

- 请先在 Issue 中描述较大的功能或架构改动，避免重复工作。
- 不要提交 API Key、签名证书、配置描述文件、真实学习资料、`store.json` 或应用导出的备份。
- UI 改动请同时验证 macOS 和 iOS Simulator；必要时在 Pull Request 中附上脱敏截图。

## 本地验证

在仓库根目录执行：

```sh
make verify-ai-plan
xcodebuild -project "study software.xcodeproj" -scheme "study software" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "study software.xcodeproj" -scheme "study software" -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 提交 Pull Request

1. Fork 仓库并从 `main` 创建功能分支。
2. 保持提交范围清晰，说明行为变化和验证方式。
3. 确认 `git diff --check`、构建和相关验证通过。
4. 提交前请确认仓库 `LICENSE` 文件中的许可条款；如果该文件尚未添加，请先与维护者确认贡献授权方式。
