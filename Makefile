APP_NAME := StudyCompanion
SOURCE_DIR := study software
MIN_MACOS := 14.0

# 每个代理使用独立的构建输出目录，避免并行构建互相覆盖。
# 用法：make BUILD_DIR=.build-g verify-integration
BUILD_DIR ?= .build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP_DIR)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources

.PHONY: all app run package \
verify-ai-plan verify-ai-protocols verify-dashboard verify-schedule verify-daily-plan verify-data-layer verify-integration verify-minimum-plan verify-entertainment verify-schedule-store clean

all: app

# ---------------------------------------------------------------------------
# 轻量 macOS .app 构建（只需要 Command Line Tools）
# ---------------------------------------------------------------------------

app: Resources/Info.plist
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	find "$(SOURCE_DIR)" -maxdepth 1 -name '*.swift' -print0 | sort -z | xargs -0 swiftc -target arm64-apple-macosx$(MIN_MACOS) -module-cache-path "$(BUILD_DIR)/ModuleCache" -parse-as-library \
		-framework SwiftUI -framework AppKit -framework Foundation -framework UniformTypeIdentifiers \
		-framework PDFKit -framework Vision -framework Security -framework UserNotifications \
		-o "$(MACOS)/$(APP_NAME)"

run: app
	open "$(APP_DIR)"

package: app
	mkdir -p dist
	ditto -c -k --keepParent "$(APP_DIR)" "dist/$(APP_NAME)-debug.zip"
	shasum -a 256 "dist/$(APP_NAME)-debug.zip" > "dist/$(APP_NAME)-debug.zip.sha256"

# ---------------------------------------------------------------------------
# 验证源码清单
#
# 这些文件只依赖 Foundation（不含 SwiftUI），因此可以被源码目标目录之外的
# 测试入口直接编译，测试代码不会被编进正式 App。
# ---------------------------------------------------------------------------

# 公共数据契约与模型：
#   A 模块 —— PlanningContracts / Models / 计划 / 会话 / 娱乐 / 迁移 / 存储
#   B 模块 —— ScheduleResolver / AvailabilityCalculator / ScheduleModels
CORE_MODEL_SOURCES := \
	"$(SOURCE_DIR)/AIPlanIntent.swift" \
	"$(SOURCE_DIR)/Models.swift" \
	"$(SOURCE_DIR)/ReviewPlanner.swift" \
	"$(SOURCE_DIR)/AIPlanIterationEngine.swift" \
	"$(SOURCE_DIR)/AIPlanDraftQualityValidator.swift" \
	"$(SOURCE_DIR)/AIPlanPatchEngine.swift" \
	"$(SOURCE_DIR)/String+StudyText.swift" \
	"$(SOURCE_DIR)/StudyContextRetriever.swift" \
	"$(SOURCE_DIR)/StudyProfileSummary.swift" \
	"$(SOURCE_DIR)/StudyFeatureInsights.swift" \
	"$(SOURCE_DIR)/ScheduleResolver.swift" \
	"$(SOURCE_DIR)/AvailabilityCalculator.swift" \
	"$(SOURCE_DIR)/ScheduleModels.swift" \
	"$(SOURCE_DIR)/StudyPlanningModels.swift" \
	"$(SOURCE_DIR)/StudySessionModels.swift" \
	"$(SOURCE_DIR)/EntertainmentModels.swift" \
	"$(SOURCE_DIR)/PlanningContracts.swift" \
	"$(SOURCE_DIR)/SnapshotMigration.swift" \
	"$(SOURCE_DIR)/PersistenceStore.swift"

# C/D/E 模块的算法引擎与 G 模块的集成层。
#
# 这里用 shell 探测而不是硬编码：某个模块还没落地时不会让整个验证目标失败，
# 一旦文件出现在源码目录里就会被自动纳入编译与验证，不需要再改 Makefile。
# 除各模块的主引擎文件外，还探测两类辅助文件：
#   · C 模块：候选构建 / 优先级 / 耗时估计 / 解释；
#   · D 模块：TaskScopeReducer（MinimumPlanPolicy 依赖它，缺了会让所有验证目标编译失败）。
#
# 注意：源码目录名含空格，`ls` 的输出必须逐个加引号再交给 swiftc，
# 否则 make 会按空格把 "study software/X.swift" 拆成两个参数导致编译失败。
QUOTE_PATHS = sed 's/.*/"&"/' | tr '\n' ' '
MODULE_SOURCES := $(shell ls "$(SOURCE_DIR)"/DailyPlanEngine.swift "$(SOURCE_DIR)"/MinimumPlanPolicy.swift "$(SOURCE_DIR)"/StudySessionEngine.swift "$(SOURCE_DIR)"/RewardEvaluator.swift 2>/dev/null | $(QUOTE_PATHS)) \
	$(shell ls "$(SOURCE_DIR)"/TaskCandidateBuilder.swift "$(SOURCE_DIR)"/TaskPriorityPolicy.swift "$(SOURCE_DIR)"/TaskDurationEstimator.swift "$(SOURCE_DIR)"/PlanExplanationBuilder.swift "$(SOURCE_DIR)"/TaskScopeReducer.swift 2>/dev/null | $(QUOTE_PATHS)) \
	"$(SOURCE_DIR)/PlanCoordination.swift" \
	"$(SOURCE_DIR)/StudyRuntimeEnvironment.swift"

# AppStore 保存链路的集成测试需要真实 Store 与存储实现，单独编译完整 app 源码
#（排除唯一的 @main App 入口），测试入口仍留在 script/ 目录之外。
SCHEDULE_STORE_TEST_SOURCES := $(shell find "$(SOURCE_DIR)" -maxdepth 1 -name '*.swift' ! -name 'StudyCompanionApp.swift' -print | $(QUOTE_PATHS))

# C 模块（今日任务自动规划）的算法源码。
#
# 如果 D 的最低价策略实现已落地，就把真实实现一并编译进来，并打开
# `CAN_USE_REAL_MINIMUM_POLICY`，让 C 的测试直接对接 D 的真实策略
# （验证"接入 D、不另写第二套压缩算法"）；D 还没落地时只跑 C 自己的测试。
# 注意：GNU make 的 $(wildcard) 处理含空格的路径不可靠（会返回空），因此这里用 shell 判断文件是否存在。
DAILY_PLAN_FLAGS := $(shell [ -f "$(SOURCE_DIR)/MinimumPlanPolicy.swift" ] && [ -f "$(SOURCE_DIR)/TaskScopeReducer.swift" ] && echo -D CAN_USE_REAL_MINIMUM_POLICY)

DAILY_PLAN_SOURCES := $(CORE_MODEL_SOURCES) $(DAILY_PLAN_FLAGS) $(MODULE_SOURCES)

# AI 规划确认链路 + 智能负荷平衡（原有验证，保持通过）。
verify-ai-plan:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(CORE_MODEL_SOURCES) $(MODULE_SOURCES) "script/verify_ai_plan_flow.swift" -o "$(BUILD_DIR)/verify_ai_plan_flow"
	"$(BUILD_DIR)/verify_ai_plan_flow"

# 四种 AI 请求协议、配置迁移、响应解析、JSON 修复和有界重试的 mock 验证。
AI_PROTOCOL_SOURCES := $(CORE_MODEL_SOURCES) "$(SOURCE_DIR)/AIProvider.swift" "$(SOURCE_DIR)/AIClient.swift" "$(SOURCE_DIR)/KeychainStore.swift"
verify-ai-protocols:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(AI_PROTOCOL_SOURCES) "script/verify_ai_protocols.swift" -framework Security -o "$(BUILD_DIR)/verify_ai_protocols"
	"$(BUILD_DIR)/verify_ai_protocols"

# 首页展示决策、离线可用性与本地无鉴权 AI 连接就绪状态验证。
DASHBOARD_SOURCES := $(CORE_MODEL_SOURCES) $(MODULE_SOURCES) "$(SOURCE_DIR)/AIProvider.swift" "$(SOURCE_DIR)/StudyHomePresentation.swift"
verify-dashboard:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(DASHBOARD_SOURCES) "script/verify_dashboard_flow.swift" -o "$(BUILD_DIR)/verify_dashboard_flow"
	"$(BUILD_DIR)/verify_dashboard_flow"

# 课表与可用时间的纯计算行为测试。
verify-schedule:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" "$(SOURCE_DIR)/ScheduleResolver.swift" "$(SOURCE_DIR)/AvailabilityCalculator.swift" "script/verify_schedule_flow.swift" -o "$(BUILD_DIR)/verify_schedule_flow"
	"$(BUILD_DIR)/verify_schedule_flow"

# C 模块（今日任务自动规划）的行为测试：
# 预算推导、层级顺序、碎片空档、硬截止冲突、100 项积压、幂等、保护任务、
# 时间增减、精力系数、每日上限、D 策略接入、解释完整性。
verify-daily-plan:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(DAILY_PLAN_SOURCES) "script/verify_daily_plan_flow.swift" -o "$(BUILD_DIR)/verify_daily_plan_flow"
	"$(BUILD_DIR)/verify_daily_plan_flow"

# 统一数据层（schema 6）的行为测试：迁移、兼容性、幂等键、备份一致性、隐私脱敏。
verify-data-layer:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(CORE_MODEL_SOURCES) "script/verify_data_layer_flow.swift" -o "$(BUILD_DIR)/verify_data_layer_flow"
	"$(BUILD_DIR)/verify_data_layer_flow"

# G 模块集成行为测试：统一提交顺序、幂等、跨日归属、奖励版本绑定、通知意图、备份往返。
verify-integration:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(CORE_MODEL_SOURCES) $(MODULE_SOURCES) "script/verify_integration_flow.swift" -o "$(BUILD_DIR)/verify_integration_flow"
	"$(BUILD_DIR)/verify_integration_flow"

# AppStore + 课表编辑写入结果：隔离快照测试写入失败、原子重试与幂等。
verify-schedule-store:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(SCHEDULE_STORE_TEST_SOURCES) "script/verify_schedule_store_flow.swift" \
		-framework SwiftUI -framework AppKit -framework Foundation -framework UniformTypeIdentifiers \
		-framework PDFKit -framework Vision -framework Security -framework UserNotifications \
		-o "$(BUILD_DIR)/verify_schedule_store_flow"
	STUDYCOMPANION_TEST_MODE=1 STUDYCOMPANION_STORE_DIR="$(abspath $(BUILD_DIR)/schedule-store-default)" "$(BUILD_DIR)/verify_schedule_store_flow"

# D 模块（最低任务 / 内容拆分 / 学习会话）的算法源码。
#
# `PlanCoordination.swift`（G）的引擎注册表现在会构造 C 的计划引擎
# （`LocalDailyPlanEngine` + `TaskSignalIndex` + 优先级/耗时/解释），
# 因此这里必须复用 `MODULE_SOURCES`；缺任何一个都会让整个目标编译不过
# （不是 D 模块本身的问题）。
MINIMUM_PLAN_SOURCES := $(CORE_MODEL_SOURCES) $(MODULE_SOURCES)

# D 模块行为测试：
# 标准/轻量/保底三档、剩余 12 分钟不返回 15 分钟任务、剩余 0 分钟不假定完成、
# 部分完成与整体完成分开、暂停不累计时长、双击完成只产生一个事件、
# 重启不丢进度也不虚增、会话幂等与中断确认、重复减量不重复执行。
verify-minimum-plan:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(MINIMUM_PLAN_SOURCES) "script/verify_minimum_plan_flow.swift" -o "$(BUILD_DIR)/verify_minimum_plan_flow"
	"$(BUILD_DIR)/verify_minimum_plan_flow"

# E 模块（娱乐解锁与奖励计时）的算法源码。
#
# 只依赖公共数据契约（A/B），不依赖 C/D 的引擎文件，因此可以和它们并行开发与验证。
ENTERTAINMENT_SOURCES := $(CORE_MODEL_SOURCES) \
	"$(SOURCE_DIR)/RewardEvaluator.swift" \
	"$(SOURCE_DIR)/EntertainmentSessionEngine.swift"

# E 模块行为测试：
# 条件进度与事件一致、低评分仍计入、跨日不累计、指定实例绑定、删除任务不等于完成、
# 空计划不解锁、撤销不计入、重复事件不重复累计、旧聚合数据不可判定、保底档位、
# 减量到零不发奖、同规则同日同档位只发一次、规则版本与历史、每周重复、
# 计时由时间戳推导（切后台/重启一致）、单计时与当天使用、通知只是意图、减量影响说明。
verify-entertainment:
	mkdir -p "$(BUILD_DIR)"
	swiftc -parse-as-library -module-cache-path "$(BUILD_DIR)/ModuleCache" $(ENTERTAINMENT_SOURCES) "script/verify_entertainment_flow.swift" -o "$(BUILD_DIR)/verify_entertainment_flow"
	"$(BUILD_DIR)/verify_entertainment_flow"

clean:
	rm -rf "$(BUILD_DIR)"
