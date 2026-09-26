# Study-Control-App

学习助手双端原型：macOS 和 iOS 均可导入资料、确认草稿、应用内作答和安排复习；iOS 另支持手机本地通知。数据默认保存在各自设备。AI 可选，支持用户自备密钥（BYOK）或明确选择无需鉴权的本地兼容服务。

> 项目状态：开发版。当前没有账号、云同步或 StoreKit 订阅功能，不应直接作为生产服务发布。

## 环境要求

- macOS 14 或更高版本
- Xcode（包含 iOS 17 / macOS 14 或更高版本 SDK）
- 可选：兼容服务的 API Key；Ollama / LM Studio 本地连接可选择无需鉴权

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

核心本地行为验证（使用合成数据和隔离临时目录，不需要私人资料或付费 AI Key）：

```sh
make verify-active-recall verify-data-layer verify-ai-plan verify-daily-plan verify-merge-import verify-document-evidence verify-integration
```

GitHub Actions 会运行这些验证及 macOS、iOS Simulator 构建。PDF 自动测试检查页码、提取方式、失败页保留、取消和扫描页的基本识别能力，不比较完整 OCR 文本。

验证四类 AI 协议与 mock 网络行为（不需要付费密钥）：

```sh
make verify-ai-protocols
```

生成本地测试包：

```sh
make package
```

输出位置：`dist/StudyCompanion-debug.zip`。这是开发测试包，不等同于 App Store 分发包或已公证的正式安装包。
同时会生成 `dist/StudyCompanion-debug.zip.sha256`，用于校验 zip 是否被改动。

源码以 `study software/` 目录中的 Xcode 目标文件为准。

## 核心操作

1. 在“导入资料”选择文件和资料类型。PDF 会逐页提取文字，扫描页尝试 OCR；导入时可查看进度并取消。关闭 AI 时资料仍可本地保存，也可手动输入文本。
2. 启用 AI 并完成分析后，在“待确认”检查草稿，再确认写入知识点、错题和复习任务。AI 生成内容不会自动成为正式学习记录。
3. 在“复习列表”新建问答卡或单空挖空卡，也可从知识点或错题制卡。应用内作答先看题面，可以输入自己的答案；点击“揭示答案”后对照来源，以中文说明对应的 0～5 分自评并保存。线下完成入口单独标为“线下自评”。
4. 错题先点“订正完成”，再通过应用内作答重做。两个不同学习日成功回忆后自动归档；错题仍保留，可人工归档、恢复或另行删除。误操作可撤销最新有效作答。
5. 在今日计划中查看预计分钟和校准说明。普通刷新保留已有估计；需要纳入最新学习记录时点“重新规划今日计划”。
6. 在“设置 → 数据工具”导出完整或隐私备份。完整备份可手动传到另一台设备，再选“合并导入另一端备份”；隐私备份会遮盖原文和引用摘录，并移除 PDF 附件。

## 双端手动传输

macOS 和 iOS 的数据分别保存在本机，**目前没有自动云同步**。在一端通过“设置 → 数据工具 → 导出完整备份”生成 JSON 文件，使用文件共享方式传到另一端，再选择“合并导入另一端备份”。完整备份会包含已保留的 PDF 附件，但不包含 Keychain 中的 API Key。

合并以稳定记录 ID 追加另一端独有的资料、卡片、作答、完成事件和计划等。相同 ID 但内容不同的记录保留本机版本，并在结果中报告冲突数；同一任务、同一学习日的完成事件按幂等键去重，已撤销的作答和完成事件不会恢复为有效。共有复习任务仍采用本机调度；另一端导入的作答保留历史，但不能用另一端的旧调度快照在本机撤销。设备设置和使用量统计保留本机值；同一天的旧打卡汇总不相加。重复导入同一备份不会重复增加记录或奖励。需要完全替换本机数据时，使用原有“导入完整备份”，并先另存本机备份。两端离线修改同一条记录产生的冲突目前需要用户自行核对。

## 已实现功能

- 本地资料库：使用 `~/Library/Application Support/StudyCompanion/store.json` 保存资料、错题、知识点、复习任务和设置
- 本地存储：单文件 JSON 快照，避免开发期 SwiftData schema 变化导致启动崩溃
- 文件导入：支持 UTF-8/Unicode 文本、Markdown、PDF、常见图片、DOCX 和 PPTX；macOS 还可尝试通过系统文本转换读取旧版 DOC/PPT
- 图片 OCR：使用 Apple Vision 框架识别图片文字
- PDF 逐页提取：优先使用 PDFKit 原生文字；无有效文字的页面用 Apple Vision OCR，支持同一文件混合页面、进度和取消
- AI 服务设置：厂商预设与协议分开选择；Base URL、模型 ID 和兼容参数保存在本地，API Key 按协议与服务地址隔离后存入 Keychain
- AI 分析：生成错题、知识点和复习计划草稿
- AI 结果校验：服务返回 JSON 异常时会尝试修复并重新解码
- 人工确认：分析结果确认后才进入正式学习库
- 复习计划：草稿没有给出任务时，本地按当天、1 天后、3 天后为每个知识点或错题建立初始任务；此后每次自评由简化 SM-2 调度，成功回忆的前两次间隔为 1 天和 6 天，后续随难易系数增长，评分低于 3 时重置为 1 天
- 今日复习：iOS 使用底部标签页展示今日任务、复习列表、知识点、错题和设置
- 复习提醒：可全局开启/关闭，也可对单个计划项关闭或延后
- 手机本地通知：iOS 使用系统本地通知按复习日期和默认提醒时间触发
- 学习答疑：先从个人笔记、错题和知识点中检索相关上下文，再让当前 AI 服务基于检索结果回答
- 答疑引用：仅显示回答实际使用且存在于本轮检索结果的资料编号；无依据时提示未检索到直接证据
- 长对话压缩：macOS 答疑会自动把较早对话压缩成长期摘要，保留近期原文，降低上下文过长导致的遗忘和请求膨胀
- 数据备份：设置页可导出/导入完整 JSON 备份
- 隐私备份：设置页可导出不含资料原文、逐页文本、分块、引用摘录、PDF 附件和诊断记录的 JSON 备份
- 数据导出：设置页可导出 Markdown 汇总，便于阅读和归档
- 错误恢复：每次保存前会保留上一次数据快照，可从设置页恢复
- 旧数据兼容：本地 JSON 支持默认值补齐，旧版数据缺少新字段时仍可打开
- 数据体检：设置页可检查草稿、错题、复习任务是否存在断开的关联
- 诊断记录：关键错误和恢复操作会进入本地诊断记录，便于排查问题
- 隐私设置：可关闭 AI 请求、关闭答疑时引用个人资料、关闭本地保存导入原文
- 模型费用统计：记录服务返回的 usage token，并按用户填写的每百万 token 单价估算费用；不同服务的费用由用户自行核对后设置
- 本地打包：`make package` 可生成开发测试 zip 包和 SHA-256 校验文件
- 编辑功能：知识点、错题、复习任务均支持内联编辑和详情编辑
- 掌握度内联调整：知识点卡片上可直接点选 0% / 25% / 50% / 75% / 100%
- 聊天对话历史：答疑页面保留完整对话记录，支持清空，每条消息有时间戳
- 连续学习天数：Dashboard 展示连续学习天数，每次完成任务自动记录
- 每日打卡：每天完成至少 1 项复习任务即自动打卡成功，Dashboard 展示今日打卡状态
- 考试目标：设置考试名称、日期、科目、每日可用时间和目标分数，Dashboard 显示倒计时，AI 规划会按最近目标和剩余天数分配复习任务
- 首次使用引导：四步 Onboarding（欢迎 → AI 服务连接 → 导入资料 → 完成）
- 网络重试：AI 请求自动进行有界重试，处理 5xx/429/可恢复网络错误并遵守 Retry-After
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

### 主动回忆与错题生命周期（第一阶段）

- 复习列表可手动建立问答或单空挖空卡；知识点和错题可一键制卡。应用内作答先显示题面，揭示答案后才允许按 0～5 的中文含义自评。无须配置 AI。
- 卡片内容、每次作答和 `ReviewTask` 调度分开保存。卡片编辑增加内容版本；旧作答保留原版本号。作答耗时只按真实开始与提交时间记录，不当作计划学习分钟。资料来源可打开已导入的原文；没有来源或页码时不会推算。
- 错题订正后仍保留；跨两个不同学习日成功回忆才自动归档。再次答错回到待重做，手动归档和恢复记录操作来源。删除仍是单独操作。
- 同日独立重做保留各自作答，但计划完成事件仍沿用任务与学习日的幂等规则，避免重复奖励。撤销最新作答会恢复调度，并联动撤销其完成依据及打卡计数。
- 第一阶段引入 schema 8；旧快照的新容器默认为空，不补造历史作答。调度接口目前使用 SM-2，FSRS 与云同步留待后续阶段。

隔离验证：`make verify-active-recall`。测试使用临时快照目录，不读取正式资料库。

### PDF 溯源与本地检索（第二阶段）

- PDF 以实际文件页序从 1 开始保存页码、提取方式和处理状态；扫描页逐页 OCR，失败页不会抹掉成功页。旧资料没有页码时明确显示“旧资料暂无页码”。
- 正文按页及段落分块，沿用原有章节标题识别。知识点、错题、卡片和聊天引用可打开已保存文本；开启“保留 PDF 原文件”后，新导入 PDF 会复制到应用管理目录，并可跳到原页。关闭并保存该设置会移除已保留的 PDF 附件。关闭“本地保存导入原文”只影响此后导入的文本。
- 学科答疑优先匹配资料、知识点和错题；学习规划优先任务和目标。按相关性、本轮字数预算及单份文档最多两个分块筛选。没有证据时不显示虚构引用。
- 完整 JSON 备份嵌入已保留的 PDF，文件可能因此变大；导入时恢复到应用管理目录。隐私备份遮盖逐页文本、分块和引用摘录，也不含附件。

隔离验证：`make verify-document-evidence`，另由 `make verify-ai-plan` 和 `make verify-data-layer` 覆盖检索、迁移与隐私导出。

### 真实耗时校准（第三阶段）

- 今日计划按科目、任务类型、完成单位及自定义单位名称筛选真实完成记录。只有已记录有效时长和正数完成量的记录会成为样本；计时会话扣除暂停，未记录、撤销及规划截点之后的记录不参与。
- 同类记录达到 5 条时，使用最近最多 20 条的单位耗时中位数估计任务量；不足 5 条仍使用原有规则。遗忘风险和掌握度仅在选定基准耗时后调整一次。
- 现有手动任务没有独立的科目字段；未关联知识点的手动任务仅用自身记录校准，避免把不同科目误合并。
- 计划项保存校准说明，普通刷新沿用已有计划的校准截点；点击“重新规划今日计划”才用最新记录。已完成项保留原预计分钟。旧计划缺少这些字段时保持原值，不补造耗时；数据 schema 升至 10。

隔离验证：`make verify-daily-plan` 覆盖样本筛选、暂停、中位数、截点、重新规划和已完成项保护。

## 真机运行说明

当前没有启用 iCloud/CloudKit entitlement。真机运行前，请在 Xcode 的 Signing & Capabilities 中选择你自己的开发团队，并将 Bundle Identifier 改成你控制的唯一标识；免费 Personal Team 也可以运行本地版 App。

如果以后要启用 Mac 与 iPhone 的实际 iCloud 同步，需要付费 Apple Developer Program 账号，并在 Xcode 的 Signing & Capabilities 中为 macOS 和 iOS 都添加 iCloud/CloudKit capability。

## AI 协议与服务范围

当前实现四类协议。厂商预设只用于填入默认地址、协议与鉴权选择；最终请求由单独选择的协议决定。模型 ID 始终可手动编辑，项目不会从某个封闭的模型清单中限制可选模型。

源码中，`study software/AIClient.swift` 负责学习业务、结构化结果修复和拒绝响应处理；`AIProvider.swift` 负责协议适配与网络传输。设置和密钥的事务回滚统一由 `AppStore` 管理，`KeychainStore` 保留旧版密钥迁移能力。

| 协议 | 请求方式 | 备注 |
| --- | --- | --- |
| OpenAI 兼容 Chat Completions | `POST {Base URL}/chat/completions` | DeepSeek、Ollama、LM Studio 和实现相同请求/响应结构的服务使用此适配器。多数兼容服务的 Base URL 以 `/v1` 结尾；DeepSeek 预设沿用其文档中的根地址。 |
| OpenAI Responses | `POST {Base URL}/responses` | OpenAI 预设的 Base URL 以 `/v1` 结尾；请求使用 Responses 的 `input`、`output_text` 和 `max_output_tokens` 结构。 |
| Anthropic Messages | `POST {Base URL}/messages` | Anthropic 预设的 Base URL 以 `/v1` 结尾；使用 `x-api-key`、`anthropic-version`、顶层 `system` 和必需的 `max_tokens`。 |
| Gemini generateContent | `POST {Base URL}/models/{model}:generateContent` | Gemini 预设的 Base URL 以 `/v1beta` 结尾；使用 `x-goog-api-key`、`contents`、`systemInstruction` 和 `generationConfig`。 |

这不是任意 API 的通用代理：服务必须实现所选协议的路径、鉴权和 JSON 结构。OpenAI 兼容也仅表示兼容 Chat Completions 适配器；不代表自动支持其它协议、流式传输、工具调用或供应商特有能力。

未配置 AI 地址、模型或密钥时，也可以保存提醒、隐私和关闭 AI 请求等本地设置。连接测试和实际 AI 请求仍需完整且有效的连接配置；保存设置不会自动发送模型请求。

配置示例（按服务文档调整 Base URL、模型 ID 和鉴权方式）：

- DeepSeek（OpenAI 兼容）：Base URL `https://api.deepseek.com`，手动填写账户当前可用的模型 ID。
- OpenAI Chat Completions：Base URL `https://api.openai.com/v1`。
- OpenAI Responses：Base URL `https://api.openai.com/v1`。
- Anthropic Messages：Base URL `https://api.anthropic.com/v1`。
- Gemini generateContent：Base URL `https://generativelanguage.googleapis.com/v1beta`。
- Ollama：Base URL `http://localhost:11434/v1`，手动填入本地已安装模型 ID，明确选择“无需鉴权”。
- LM Studio：Base URL `http://localhost:1234/v1`，在 LM Studio 启动兼容服务器后手动填入已加载模型 ID，明确选择“无需鉴权”。

Base URL 统一表示 API 根地址，包含服务要求的版本路径和自定义代理前缀（例如 `/v1` 或 `/v1beta`）；应用只附加所选协议的接口路径，不会猜测或重复添加版本段。末尾斜杠会归一化；若粘贴了已知完整接口地址，应用会移除接口部分并保留版本和代理前缀。界面不会自动获取或推测模型清单。`temperature` 可留空；原生 JSON 模式按用户配置选择，关闭时仍保留提示词、JSON 提取和一次修复流程。

官方接口参考：

- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [OpenAI Responses](https://developers.openai.com/api/docs/guides/text)
- [Anthropic Messages](https://docs.anthropic.com/en/api/messages)
- [Gemini generateContent](https://ai.google.dev/api/generate-content)
- [Ollama OpenAI compatibility](https://docs.ollama.com/openai)
- [LM Studio OpenAI compatibility](https://lmstudio.ai/docs/developer/openai-compat)

## 安全与隐私

- 仓库不包含任何服务 API Key，也不会替用户提供共享密钥。
- API Key 保存在系统 Keychain，并按协议和服务地址隔离；启用模型请求后，用户选择的学习内容会发送到设置中的 Base URL。无鉴权模式不会发送 Authorization 或供应商密钥头。
- 旧版 `local.studycompanion.deepseek` Keychain 项目仍可读取；只有已存在的旧版本地配置会把它迁移到该配置原有的 Chat Completions 地址。迁移成功前不删除旧项；导入或恢复备份会关闭旧密钥回退，避免把密钥绑定到备份中的地址。
- 不要把真实 API Key、本地 `store.json`、学习资料备份或个人截图提交到仓库或 Issue。
- 导入来源不明的备份前，请确认其中的 AI Base URL 和协议；它决定请求将发送到哪里。备份不含 API Key。
- 本地 HTTP 仅对本地网络配置了 ATS 例外（`NSAllowsLocalNetworking`），没有全局放宽 ATS。iOS 访问局域网中的电脑服务时，系统可能显示本地网络访问提示；请在服务端按需开启监听并自行保护局域网。

## 参与贡献

提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题的报告方式见 [SECURITY.md](SECURITY.md)。

由于是主要vibe coding出来练手学习的项目，所以有太多不足了，恳请多多指教和批评，以上的readme内容也都是ai出来的内容，恳请指出错误与不足
