import Foundation

// MARK: - E 模块：娱乐解锁与奖励评估
//
// 公共接口职责表：
//   RewardEvaluator | 规则、计划、完成事件、奖励记录 | 条件进度、资格、待发放奖励
//
// 硬约束：
// - 纯计算：不写文件、不发通知、不改全局状态；时间只来自 `PlanningContext`。
// - 资格只认「真实完成事件」，不读 `ReviewTask.status`、不读网络。
// - 学习日一律用 `summary.dayKey`：昨天完成同一个知识点不会解锁今天。
// - 同一事件不会重复累计；撤销事件不计入。
// - 答题正确与否不参与判定（评分低但确实完成了，仍按规则计入）。
// - 空计划 / 无学习记录不能靠"全部完成"或"保底"拿到奖励。

// MARK: - 完成事件账本（统一口径）

/// 娱乐资格的事件账本。
enum EntertainmentEventLedger {
    /// 当日、未撤销、已按 id 与幂等键去重的事件。
    ///
    /// 去重是防御性的：调用方重复传入同一个事件也不会把进度算成两倍。
    static func activeEvents(_ completions: [CompletionEvent], dayKey: StudyDayKey) -> [CompletionEvent] {
        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()
        return completions.filter { event in
            guard event.dayKey == dayKey, !event.isRevoked else { return false }
            guard seenIDs.insert(event.id).inserted else { return false }
            return seenKeys.insert(event.idempotencyKey).inserted
        }
    }

    /// 是否构成"真实学习"信号：有实际时长，或有正的实际完成范围。
    ///
    /// 注意：`assessment`（答题正确数/自评）刻意不参与，低评分但完成了仍然计入。
    static func isStudySignal(_ event: CompletionEvent) -> Bool {
        event.actualMinutes > 0 || event.completedScope.isPositive
    }
}

// MARK: - 目标绑定匹配

extension EntertainmentTargetBinding {
    /// 某个完成事件是否命中该绑定。
    ///
    /// 三个必要条件：
    /// 1. 事件属于**同一个学习日**；
    /// 2. 事件未被撤销；
    /// 3. 绑定的实例 ID（以及绑定自带的学习日，若有）与事件一致。
    func matches(_ event: CompletionEvent, on dayKey: StudyDayKey) -> Bool {
        guard event.dayKey == dayKey, !event.isRevoked else { return false }
        if let boundDay = self.dayKey, boundDay != dayKey { return false }
        switch kind {
        case .planItem:
            return event.planItemID == id
        case .reviewTask:
            return event.source?.reviewTaskID == id
        case .courseOccurrence:
            return event.source?.occurrenceID == id
        case .knowledgePoint:
            return event.source?.knowledgePointID == id
        }
    }
}

// MARK: - 发放语义

/// 判断"编辑后的规则是否还是同一个奖励档位"。
///
/// 用途：同一规则、同一学习日、同一档位只发放一次。仅仅切换启用状态、
/// 或只改了展示文案的编辑，不会凭空多出一次发放。

// MARK: - 评估器

/// 娱乐奖励评估器（`RewardEvaluator` 的生产实现）。
struct EntertainmentRewardEvaluator: RewardEvaluator {

    func evaluate(
        rules: [EntertainmentRule],
        plan: DailyStudyPlan?,
        completions: [CompletionEvent],
        grants: [RewardGrant],
        summary: DailyStudySummary,
        context: PlanningContext
    ) -> RewardEvaluation {
        let dayKey = summary.dayKey
        let dayEvents = EntertainmentEventLedger.activeEvents(completions, dayKey: dayKey)
        let effectiveRules = rules.filter { $0.isEffective(on: dayKey, calendar: context.calendar) }

        var evaluation = RewardEvaluation()

        // 旧版本的"每日完成总数"没有明细与时长：如实不可判定，绝不推算。
        guard RewardEligibilityGuard.isDecidable(summary: summary) else {
            evaluation.undecidableRuleRevisionIDs = effectiveRules.map(\.revisionID)
            evaluation.explanation.append(RewardEligibilityGuard.undecidableExplanation(for: dayKey))
            evaluation.explanation.append("为避免凭空补发，旧版本每日总数不参与娱乐资格判定。")
            return evaluation
        }

        guard !effectiveRules.isEmpty else {
            evaluation.explanation.append("\(dayKey.localDateString) 没有生效的娱乐规则。")
            return evaluation
        }

        let inputs = EntertainmentRuleInputs(
            dayKey: dayKey,
            plan: plan,
            dayEvents: dayEvents,
            summary: summary
        )

        for rule in effectiveRules {
            let outcome = Self.evaluateRule(rule, inputs: inputs, context: context)
            evaluation.progress.append(outcome.progress)
            evaluation.explanation.append(contentsOf: outcome.notes)

            guard let minutes = outcome.grantedMinutes else { continue }
            evaluation.eligibleRuleRevisionIDs.append(rule.revisionID)

            guard let grant = Self.makeGrant(
                rule: rule,
                dayKey: dayKey,
                outcome: outcome,
                grantedMinutes: minutes,
                grants: grants,
                context: context
            ) else {
                evaluation.explanation.append("「\(rule.name)」今天已经发放过同一档位奖励，未重复发放。")
                continue
            }
            evaluation.pendingGrants.append(grant)
            evaluation.explanation.append(
                "「\(rule.name)」已达标，发放 \(grant.grantedMinutes) 分钟（规则第 \(rule.ruleVersion) 版）。"
            )
        }

        return evaluation
    }
}

// MARK: - 输入与结果

/// 单条规则评估所需的当日输入。
struct EntertainmentRuleInputs {
    var dayKey: StudyDayKey
    var plan: DailyStudyPlan?
    var dayEvents: [CompletionEvent]
    var summary: DailyStudySummary

    /// 当天是否存在真实学习信号。
    var hasStudySignal: Bool {
        dayEvents.contains { EntertainmentEventLedger.isStudySignal($0) }
    }

    /// 当天计划项 ID 集合（空表示"没有计划任务"）。
    var plannedItemIDs: Set<UUID> {
        Set(plan?.items.map(\.id) ?? [])
    }
}

/// 单条规则的评估结果。
struct EntertainmentRuleOutcome {
    var progress: RewardConditionProgress
    /// `nil` 表示不发放。
    var grantedMinutes: Int?
    /// 面向界面的中文说明（含"需要调整规则"的提示）。
    var notes: [String]
}

// MARK: - 度量口径

extension EntertainmentRewardEvaluator {

    /// 一个度量口径的读数。
    struct MetricReading {
        var value: Double
        var basisEventIDs: [UUID]
        var detail: String
    }

    /// 按契约口径读取当日进度。旧版本每日总数不参与任何口径。
    static func reading(for metric: RewardMetric, inputs: EntertainmentRuleInputs) -> MetricReading {
        switch metric {
        case .standardCompletedItemCount:
            let events = inputs.dayEvents.filter { $0.tier == .standard }
            return MetricReading(
                value: Double(events.count),
                basisEventIDs: events.map(\.id),
                detail: "标准完成 \(events.count) 项"
            )

        case .minimumCompletedItemCount:
            let events = inputs.dayEvents.filter { $0.tier.satisfiesMinimum }
            return MetricReading(
                value: Double(events.count),
                basisEventIDs: events.map(\.id),
                detail: "保底完成及以上 \(events.count) 项"
            )

        case .studiedItemCount:
            // 只统计"真实学习信号"：0 范围 + 0 时长的记录不算学习，
            // 否则"减量到零"就能刷出进度。
            let events = inputs.dayEvents.filter { $0.tier == .studied && EntertainmentEventLedger.isStudySignal($0) }
            return MetricReading(
                value: Double(events.count),
                basisEventIDs: events.map(\.id),
                detail: "已学习 \(events.count) 项"
            )

        case .recordedMinutes:
            let events = inputs.dayEvents.filter { $0.actualMinutes > 0 }
            let minutes = events.reduce(0) { $0 + $1.actualMinutes }
            return MetricReading(
                value: Double(minutes),
                basisEventIDs: events.map(\.id),
                detail: "记录时长 \(minutes) 分钟"
            )

        case .standardCompletionRatio:
            let planned = inputs.plan?.items.count ?? 0
            let events = inputs.dayEvents.filter { $0.tier == .standard }
            guard planned > 0 else {
                return MetricReading(value: 0, basisEventIDs: [], detail: "当天没有计划任务，完成比例为 0")
            }
            return MetricReading(
                value: min(1, Double(events.count) / Double(planned)),
                basisEventIDs: events.map(\.id),
                detail: "标准完成 \(events.count)/\(planned) 项"
            )

        case .anyStudied:
            let events = inputs.dayEvents.filter { EntertainmentEventLedger.isStudySignal($0) }
            return MetricReading(
                value: events.isEmpty ? 0 : 1,
                basisEventIDs: events.map(\.id),
                detail: events.isEmpty ? "当天没有学习记录" : "当天有 \(events.count) 条学习记录"
            )
        }
    }

    /// 当天完成比例：保底及以上完成数 / 计划任务数（0...1）。
    ///
    /// 保底适配方式（`EntertainmentFallbackMode`）要的是"今天到底学了多少"，
    /// 而不是某条规则自己的条件比例：例如条件要求"标准完成 2 项"，用户只做到
    /// 保底 1 项时，条件比例是 0，但当天完成比例是 1/2，保底档位应当照常发放。
    /// 没有计划时退化为"有学习记录 = 1，没有 = 0"。
    static func dayCompletionRatio(inputs: EntertainmentRuleInputs) -> Double {
        let planned = inputs.plan?.items.count ?? 0
        if planned > 0 {
            let completed = inputs.dayEvents.filter { $0.tier.satisfiesMinimum }.count
            return min(1, Double(completed) / Double(planned))
        }
        return inputs.hasStudySignal ? 1 : 0
    }

    /// 目标绑定读数：全部绑定都命中才算满足。
    struct TargetReading {
        var isSatisfied: Bool
        var satisfiedCount: Int
        var totalCount: Int
        var missing: [EntertainmentTargetBinding]
        var basisEventIDs: [UUID]
        /// 绑定可能已经失效（任务被删除 / 计划重排），规则需要用户确认调整。
        var needsAdjustment: Bool
        var notes: [String]
    }

    /// `nil` 表示该规则没有绑定任何具体实例（通用条件）。
    static func targetReading(rule: EntertainmentRule, inputs: EntertainmentRuleInputs) -> TargetReading? {
        let targets = rule.boundTargets
        guard !targets.isEmpty else { return nil }

        let plannedItemIDs = inputs.plannedItemIDs
        let hasPlan = !plannedItemIDs.isEmpty
        let knownReviewTaskIDs = Set(inputs.plan?.items.compactMap { $0.source.reviewTaskID } ?? [])
        let knownOccurrenceIDs = Set(inputs.plan?.items.compactMap { $0.source.occurrenceID } ?? [])
        let knownKnowledgePointIDs = Set(inputs.plan?.items.compactMap { $0.source.knowledgePointID } ?? [])

        var satisfiedEventIDs: [UUID] = []
        var missing: [EntertainmentTargetBinding] = []
        var needsAdjustment = false
        var notes: [String] = []

        for target in targets {
            let matched = inputs.dayEvents.filter { target.matches($0, on: inputs.dayKey) }
            if !matched.isEmpty {
                satisfiedEventIDs.append(contentsOf: matched.map(\.id))
                continue
            }

            missing.append(target)

            if let boundDay = target.dayKey, boundDay != inputs.dayKey {
                notes.append("「\(rule.name)」绑定的\(target.displayText)属于其他学习日，今天不适用，不会解锁。")
                continue
            }

            let name = target.displayName.isEmpty ? target.kind.label : target.displayName

            switch target.kind {
            case .planItem:
                if !hasPlan {
                    notes.append("「\(rule.name)」绑定了计划任务「\(name)」，但今天没有任何计划任务，无法解锁。")
                } else if !plannedItemIDs.contains(target.id) {
                    needsAdjustment = true
                    notes.append("「\(rule.name)」绑定的计划任务「\(name)」已不在今天的计划里（可能已被删除或计划已重排），规则需要调整，不会自动解锁。")
                } else {
                    notes.append("「\(rule.name)」绑定的计划任务「\(name)」今天还没有完成记录。")
                }

            case .reviewTask:
                if knownReviewTaskIDs.contains(target.id) {
                    notes.append("「\(rule.name)」绑定的复习任务「\(name)」今天还没有完成记录。")
                } else if hasPlan {
                    needsAdjustment = true
                    notes.append("「\(rule.name)」绑定的复习任务「\(name)」今天既没有完成记录，也不在今天计划的复习任务里；可能已被删除，请调整规则（不会自动解锁）。")
                } else {
                    notes.append("「\(rule.name)」绑定的复习任务「\(name)」今天没有计划也没有完成记录，无法解锁。")
                }

            case .courseOccurrence:
                if knownOccurrenceIDs.contains(target.id) {
                    notes.append("「\(rule.name)」绑定的课程实例「\(name)」今天还没有完成记录。")
                } else if hasPlan {
                    needsAdjustment = true
                    notes.append("「\(rule.name)」绑定的课程实例「\(name)」不在今天的计划里；如果该课程已被删除，请调整规则（不会自动解锁）。")
                } else {
                    notes.append("「\(rule.name)」绑定的课程实例「\(name)」今天没有计划也没有完成记录，无法解锁。")
                }

            case .knowledgePoint:
                if knownKnowledgePointIDs.contains(target.id) {
                    notes.append("「\(rule.name)」绑定的知识点「\(name)」今天还没有完成记录。")
                } else if hasPlan {
                    needsAdjustment = true
                    notes.append("「\(rule.name)」绑定的知识点「\(name)」今天没有匹配的完成记录，也不在今天计划的知识点里；请确认绑定是否仍然有效（不会自动解锁）。")
                } else {
                    notes.append("「\(rule.name)」绑定的知识点「\(name)」今天没有计划也没有完成记录，无法解锁。")
                }
            }
        }

        return TargetReading(
            isSatisfied: missing.isEmpty,
            satisfiedCount: targets.count - missing.count,
            totalCount: targets.count,
            missing: missing,
            basisEventIDs: satisfiedEventIDs,
            needsAdjustment: needsAdjustment,
            notes: notes
        )
    }

    /// 单条规则的完整判定：度量条件与目标绑定**全部满足**才算达标。
    static func evaluateRule(
        _ rule: EntertainmentRule,
        inputs: EntertainmentRuleInputs,
        context: PlanningContext
    ) -> EntertainmentRuleOutcome {
        let reading = Self.reading(for: rule.condition.metric, inputs: inputs)
        let required = rule.condition.requiredValue
        let metricSatisfied = required > 0 && reading.value >= required

        let targets = Self.targetReading(rule: rule, inputs: inputs)
        let targetsSatisfied = targets?.isSatisfied ?? true
        let isSatisfied = metricSatisfied && targetsSatisfied

        var basisIDs = Set(reading.basisEventIDs)
        if let targets { basisIDs.formUnion(targets.basisEventIDs) }

        var detailParts = [reading.detail]
        if let targets {
            detailParts.append("指定实例 \(targets.satisfiedCount)/\(targets.totalCount) 已匹配")
            if !targets.missing.isEmpty {
                detailParts.append("未匹配：" + targets.missing.map(\.displayText).joined(separator: "、"))
            }
        }

        let progress = RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: rule.condition.metric,
            achievedValue: reading.value,
            requiredValue: required,
            detail: detailParts.joined(separator: "；"),
            basisEventIDs: basisIDs.sorted { $0.uuidString < $1.uuidString },
            isSatisfied: isSatisfied
        )

        var notes = targets?.notes ?? []

        guard rule.rewardMinutes > 0 else {
            notes.append("「\(rule.name)」奖励时长为 0 分钟，不发放奖励。")
            return EntertainmentRuleOutcome(progress: progress, grantedMinutes: nil, notes: notes)
        }

        if isSatisfied {
            return EntertainmentRuleOutcome(progress: progress, grantedMinutes: rule.rewardMinutes, notes: notes)
        }

        // 关键防线：当天完全没有学习时，任何保底方式都不发放。
        // 这同时挡住"不断减量到零即可获得奖励"的路径。
        guard inputs.hasStudySignal else {
            notes.append("「\(rule.name)」未达标：当天没有有效学习记录，保底不发奖励。")
            return EntertainmentRuleOutcome(progress: progress, grantedMinutes: nil, notes: notes)
        }

        guard let fallbackMinutes = rule.fallback.grantedMinutes(
            ruleMinutes: rule.rewardMinutes,
            isConditionSatisfied: false,
            achievedRatio: Self.dayCompletionRatio(inputs: inputs)
        ) else {
            let detail = rule.fallback == .none
                ? "未达标，且没有开启保底替代。"
                : "未达标，当前保底方式（\(rule.fallback.label)）不发放奖励。"
            notes.append("「\(rule.name)」\(detail)")
            return EntertainmentRuleOutcome(progress: progress, grantedMinutes: nil, notes: notes)
        }

        notes.append("「\(rule.name)」未达标，按保底方式（\(rule.fallback.label)）发放 \(fallbackMinutes) 分钟；标准档位为 \(rule.rewardMinutes) 分钟。")
        return EntertainmentRuleOutcome(progress: progress, grantedMinutes: fallbackMinutes, notes: notes)
    }

    /// 生成待发放奖励。重复发放在此被拦下。
    static func makeGrant(
        rule: EntertainmentRule,
        dayKey: StudyDayKey,
        outcome: EntertainmentRuleOutcome,
        grantedMinutes: Int,
        grants: [RewardGrant],
        context: PlanningContext
    ) -> RewardGrant? {
        let key = RewardGrant.Key.make(ruleRevisionID: rule.revisionID, dayKey: dayKey)
        guard !grants.contains(where: { $0.grantKey == key }) else { return nil }

        // 同一规则 + 同一学习日只产生一次收益。资格核验仍会独立运行，
        // 但编辑规则、撤销后重新达标或重复刷新都不能再发一份奖励。
        guard !grants.contains(where: { $0.dayKey == dayKey && $0.ruleID == rule.id }) else { return nil }

        return RewardGrant.make(
            ruleSnapshot: rule.snapshotValue,
            dayKey: dayKey,
            basisEventIDs: outcome.progress.basisEventIDs,
            conditionProgress: outcome.progress,
            grantedMinutes: grantedMinutes,
            grantedAt: context.now
        )
    }
}

// MARK: - 减量 / 保底对奖励的影响（供 D 模块展示）

/// 一次减量对某条娱乐规则的影响。
struct EntertainmentReductionImpact: Identifiable, Hashable, Sendable {
    var ruleID: UUID
    var ruleName: String
    /// 不减量、达标时的奖励分钟。
    var standardMinutes: Int
    /// 减量后（只完成保底范围）预计可拿到的分钟。
    var reducedMinutes: Int
    /// 减量后是否完全拿不到奖励。
    var losesEntitlement: Bool
    /// 条件本身是否会因减量而改变（指定任务 / 固定时长条件不受减量影响）。
    var conditionIsReductionProof: Bool
    /// 可直接写入 `DailyPlanExplanation.lines` 的说明行。
    var lines: [String]

    var id: UUID { ruleID }
}

/// 减量预览的奖励影响说明。
///
/// 纯计算：只做"假设用户完成保底范围"的**预估**，并在文案里明确写"预计"，
/// 不写文件、不改计划。
enum EntertainmentRewardImpactAdvisor {

    static func impacts(
        rules: [EntertainmentRule],
        plan: DailyStudyPlan?,
        minimumPlan: DailyStudyPlan?,
        completions: [CompletionEvent],
        summary: DailyStudySummary,
        context: PlanningContext
    ) -> [EntertainmentReductionImpact] {
        guard RewardEligibilityGuard.isDecidable(summary: summary) else { return [] }
        let dayKey = summary.dayKey
        let dayEvents = EntertainmentEventLedger.activeEvents(completions, dayKey: dayKey)
        let effectiveRules = rules.filter { $0.isEffective(on: dayKey, calendar: context.calendar) }
        guard !effectiveRules.isEmpty else { return [] }

        let currentInputs = EntertainmentRuleInputs(dayKey: dayKey, plan: plan, dayEvents: dayEvents, summary: summary)

        // 减量后：只有保底范围的任务按"保底完成"预估，其余仍按完整范围预估。
        let reducedItems = minimumPlan?.items ?? []
        let reducedEvents = reducedItems.map {
            reducedProjectionEvent(for: $0)
        }
        let reducedSummary = projectedSummary(items: reducedItems, plan: minimumPlan, dayKey: dayKey)
        let reducedInputs = EntertainmentRuleInputs(
            dayKey: dayKey,
            plan: minimumPlan,
            dayEvents: reducedEvents,
            summary: reducedSummary
        )

        return effectiveRules.map { rule in
            let currentOutcome = EntertainmentRewardEvaluator.evaluateRule(rule, inputs: currentInputs, context: context)
            let reducedOutcome = EntertainmentRewardEvaluator.evaluateRule(rule, inputs: reducedInputs, context: context)
            let standardMinutes = rule.rewardMinutes
            let reducedMinutes = reducedOutcome.grantedMinutes ?? 0
            let reductionProof = !rule.boundTargets.isEmpty || rule.condition.metric == .recordedMinutes

            var lines: [String] = []
            if minimumPlan == nil || minimumPlan?.items.isEmpty == true {
                lines.append("娱乐规则「\(rule.name)」：当天没有可执行的保底任务，减量后预计没有奖励（标准档位 \(standardMinutes) 分钟）。")
            } else if reductionProof {
                lines.append("娱乐规则「\(rule.name)」：条件是指定任务/固定时长，不受自动减量影响（标准档位 \(standardMinutes) 分钟，当前进度 \(currentOutcome.progress.detail)）。")
            } else if reducedMinutes == standardMinutes && standardMinutes > 0 {
                lines.append("娱乐规则「\(rule.name)」：减量后仍预计发放 \(reducedMinutes) 分钟。")
            } else if reducedMinutes > 0 {
                lines.append("娱乐规则「\(rule.name)」：减量后预计奖励从 \(standardMinutes) 分钟降为 \(reducedMinutes) 分钟（\(rule.fallback.label)）。")
            } else {
                lines.append("娱乐规则「\(rule.name)」：减量后预计拿不到奖励；需要达到标准档位 \(standardMinutes) 分钟的条件。")
            }
            if let targetNote = reducedOutcome.notes.first {
                lines.append("娱乐规则「\(rule.name)」：\(targetNote)")
            }

            return EntertainmentReductionImpact(
                ruleID: rule.id,
                ruleName: rule.name,
                standardMinutes: standardMinutes,
                reducedMinutes: reducedMinutes,
                losesEntitlement: reducedMinutes == 0,
                conditionIsReductionProof: reductionProof,
                lines: lines
            )
        }
    }

    /// 减量方案的预估完成事件：有保底范围的任务按保底完成，其余按标准完成。
    ///
    /// 这是一个**预估**（假设用户完成保底范围），ID 由稳定哈希派生，便于测试比对。
    static func reducedProjectionEvent(for item: DailyPlanItem) -> CompletionEvent {
        let usesMinimum = item.minimumScope != nil
        let scope = item.minimumScope ?? item.plannedScope
        let key = "reward-impact|item:\(item.id.uuidString)|tier:\(usesMinimum ? "minimum" : "standard")"
        let tier: PlanCompletionTier = usesMinimum ? .minimum : .standard
        return CompletionEvent(
            id: StudyStableKey.uuid(from: key),
            idempotencyKey: key,
            sessionID: nil,
            planID: item.planID,
            planItemID: item.id,
            dayKey: item.scheduledDayKey,
            source: item.source,
            plannedScope: item.plannedScope,
            completedScope: scope,
            tier: tier,
            actualMinutes: item.estimatedMinutes,
            completedAt: item.scheduledStart ?? StudyTimestamp.unspecified,
            assessment: nil,
            note: "减量预估",
            createdAt: StudyTimestamp.unspecified
        )
    }

    static func projectedSummary(
        items: [DailyPlanItem],
        plan: DailyStudyPlan?,
        dayKey: StudyDayKey
    ) -> DailyStudySummary {
        let standard = items.filter { $0.minimumScope == nil }.count
        let minimum = items.filter { $0.minimumScope != nil }.count
        let minutes = items.reduce(0) { $0 + $1.estimatedMinutes }
        return DailyStudySummary(
            dayKey: dayKey,
            source: items.isEmpty ? .none : .recordedEvents,
            standardCompletedItemCount: standard,
            minimumCompletedItemCount: minimum,
            studiedItemCount: 0,
            recordedMinutes: items.isEmpty ? nil : minutes,
            legacyCompletedTaskCount: nil,
            isEntertainmentEligible: (standard + minimum) > 0,
            planID: plan?.id,
            planMode: plan?.mode,
            explanation: "减量预估：标准 \(standard) 项、保底 \(minimum) 项，预计 \(minutes) 分钟。"
        )
    }
}
