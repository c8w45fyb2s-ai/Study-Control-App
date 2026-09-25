# Study-Control-App

学习助手双端原型：macOS 端负责资料导入、OCR/PDF 文本提取、DeepSeek 分析和人工确认；iOS 端负责今日复习、提醒管理和手机本地通知。数据默认保存在本机，AI 功能采用用户自备 API Key（BYOK）。

> 项目状态：开发版。当前没有账号、云同步或 StoreKit 订阅功能，不应直接作为生产服务发布。

## 环境要求

- macOS 14 或更高版本
- Xcode（包含 iOS 17 / macOS 14 或更高版本 SDK）
- 可选：DeepSeek API Key，用于 AI 分析和学习答疑

## 运行方式

克隆仓库后，在仓库根目录打开 Xcode 工程：

```sh
open "study software.xcodeproj"
```

命令行验证 macOS：

```sh
xcodebuild -project "study software.xcodeproj" -scheme "study software" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

命令行验证 iOS Simulator：

```sh
xcodebuild -project "study software.xcodeproj" -scheme "study software" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

本机只有 Command Line Tools 时，也可以用轻量 `Makefile` 编译 macOS `.app`：

```sh
make run
```

验证 AI 规划确认链路：

```sh
make verify-ai-plan
```

生成本地测试包：

```sh
make package
```

输出位置：`dist/StudyCompanion-debug.zip`。这是开发测试包，不等同于 App Store 分发包或已公证的正式安装包。
同时会生成 `dist/StudyCompanion-debug.zip.sha256`，用于校验 zip 是否被改动。

源码以 `study software/` 目录中的 Xcode 目标文件为准。

## 已实现功能

- 本地资料库：使用 `~/Library/Application Support/StudyCompanion/store.json` 保存资料、错题、知识点、复习任务和设置
- 本地存储：单文件 JSON 快照，避免开发期 SwiftData schema 变化导致启动崩溃
- 文件导入：支持文本、Markdown、PDF 和常见图片
- 图片 OCR：使用 Apple Vision 框架识别图片文字
- PDF 文本提取：使用 PDFKit
- DeepSeek API 设置：API Key 存入 Keychain，Base URL 和模型存入本地设置
- AI 分析：生成错题、知识点和复习计划草稿
- AI 结果校验：DeepSeek 返回 JSON 异常时会尝试修复并重新解码
- 人工确认：分析结果确认后才进入正式学习库
- 复习计划：DeepSeek 未返回计划时，本地按 0/1/3/7/14 天生成兜底计划，并按掌握度设置优先级
- 今日复习：iOS 使用底部标签页展示今日任务、复习列表、知识点、错题和设置
- 复习提醒：可全局开启/关闭，也可对单个计划项关闭或延后
- 手机本地通知：iOS 使用系统本地通知按复习日期和默认提醒时间触发
- 学习答疑：先从个人笔记、错题和知识点中检索相关上下文，再让 DeepSeek 基于检索结果回答
- 答疑引用：答疑页会显示本次检索到的个人资料，便于确认回答依据
- 长对话压缩：macOS 答疑会自动把较早对话压缩成长期摘要，保留近期原文，降低上下文过长导致的遗忘和请求膨胀
- 数据备份：设置页可导出/导入完整 JSON 备份
- 隐私备份：设置页可导出不含资料原文和诊断记录的 JSON 备份
- 数据导出：设置页可导出 Markdown 汇总，便于阅读和归档
- 错误恢复：每次保存前会保留上一次数据快照，可从设置页恢复
- 旧数据兼容：本地 JSON 支持默认值补齐，旧版数据缺少新字段时仍可打开
- 数据体检：设置页可检查草稿、错题、复习任务是否存在断开的关联
- 诊断记录：关键错误和恢复操作会进入本地诊断记录，便于排查问题
- 隐私设置：可关闭 AI 请求、关闭答疑时引用个人资料、关闭本地保存导入原文
- 模型费用统计：记录 DeepSeek 返回的 usage token，并按用户填写的每百万 token 单价估算费用
- 本地打包：`make package` 可生成开发测试 zip 包和 SHA-256 校验文件
- 编辑功能：知识点、错题、复习任务均支持内联编辑和详情编辑
- 掌握度内联调整：知识点卡片上可直接点选 0% / 25% / 50% / 75% / 100%
- 聊天对话历史：答疑页面保留完整对话记录，支持清空，每条消息有时间戳
- 连续学习天数：Dashboard 展示连续学习天数，每次完成任务自动记录
- 每日打卡：每天完成至少 1 项复习任务即自动打卡成功，Dashboard 展示今日打卡状态
- 考试目标：设置考试名称、日期、科目、每日可用时间和目标分数，Dashboard 显示倒计时，AI 规划会按最近目标和剩余天数分配复习任务
- 首次使用引导：四步 Onboarding（欢迎 → API Key → 导入资料 → 完成）
- 网络重试：DeepSeek 请求自动重试（可配置次数，指数退避），处理 5xx/429/网络中断
- macOS 键盘快捷键：Cmd+1~8 切换功能页，Cmd+, 打开设置
- 数据可视化：Dashboard 展开"学习趋势"可查看最近 7 天完成柱状图、掌握度分布条和完成率统计
- Anki 导出：设置页可导出 .tsv 文件，包含错题（Front/Back/Tags）和知识点（Front/Back/Tags），可直接导入 Anki
- 触觉反馈：iOS 端完成任务、确认草稿、调整掌握度、保存设置等操作有触觉反馈（.success / .selection）
- 无障碍支持：关键交互元素添加了 accessibilityLabel、accessibilityHint、accessibilityValue，知识点卡片和图表区域标注为组合元素
- 学习日历：按日期聚合待复习任务、已完成记录和考试节点，支持从日历进入复习计划
- 考试冲刺模式：根据考试倒计时自动划分基础补齐、强化训练、模拟冲刺和考前收束阶段，并生成今日动作建议
- 智能负荷平衡：按每日可用时间估算未来复习负荷，识别超载日期，生成 30 分钟压缩清单，并可一键顺延低优先级任务
- 知识图谱：将科目、知识点、错题和资料来源构造成节点与连接，帮助定位薄弱关系
- 资料章节索引：从 Markdown 标题、章节编号、页码标记或长文本片段中自动生成资料章节视图
- 学习报告增强：在周/月报告基础上增加任务负荷预测、遗忘风险、预计清理天数和薄弱/错因聚合

## 真机运行说明

当前没有启用 iCloud/CloudKit entitlement。真机运行前，请在 Xcode 的 Signing & Capabilities 中选择你自己的开发团队，并将 Bundle Identifier 改成你控制的唯一标识；免费 Personal Team 也可以运行本地版 App。

如果以后要启用 Mac 与 iPhone 的实际 iCloud 同步，需要付费 Apple Developer Program 账号，并在 Xcode 的 Signing & Capabilities 中为 macOS 和 iOS 都添加 iCloud/CloudKit capability。

## DeepSeek（暂时支持DS）

默认配置：

- Base URL: `https://api.deepseek.com`
- Model: `deepseek-v4-flash`

你需要在 App 的“设置”中填入自己的 DeepSeek API Key。

## 安全与隐私

- 仓库不包含任何 DeepSeek API Key，也不会替用户提供共享密钥。
- API Key 保存在系统 Keychain；启用模型请求后，用户选择的学习内容会发送到设置中的 Base URL。
- 不要把真实 API Key、本地 `store.json`、学习资料备份或个人截图提交到仓库或 Issue。
- 导入来源不明的备份前，请确认其中的 AI Base URL；它决定模型请求和 Bearer Key 将发送到哪里。

## 参与贡献

提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题的报告方式见 [SECURITY.md](SECURITY.md)。

由于是主要vibe coding出来练手学习的项目，所以有太多不足了，恳请多多指教和批评，以下的readme内容也都是ai出来的内容，恳请指出错误与不足
