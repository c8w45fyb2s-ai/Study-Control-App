import SwiftUI

// MARK: - G 模块：会话恢复与收尾
//
// 需求 3 / 5 / 6 的落点，全部接入正式调用链：
// - 「放弃学习」：真的把会话置为 abandoned（不是又一次暂停）；
// - 「记录进度」：真的把范围写进会话与计划项；
// - 「手动补记时长」：真的修正有效时长，并保留来源与原因；
// - 「中断确认」：切后台/崩溃后的未知时间由用户确认，或按规则排除；
// - 「跨日遗留会话」：可见、可结束、可放弃，且不会阻止刷新。
//
// 页面只读快照 + 回调，写入全部经过 AppStore 的统一提交入口。

struct StudySessionRecoveryCard: View {
    @EnvironmentObject private var store: AppStore

    @State private var progressSessionID: UUID?
    @State private var targetMinutes = 30
    @State private var adjustmentReason = "用户补记"

    private var now: Date { Date() }

    private var interruptions: [(session: StudySession, interruption: StudySessionInterruption)] {
        store.sessionsAwaitingInterruptionDecision(now: now)
    }

    private var staleSessions: [StudySession] {
        store.staleActiveSessions
    }

    private var activeSession: StudySession? {
        store.todayActiveSession
    }

    private var hasAnything: Bool {
        !interruptions.isEmpty || !staleSessions.isEmpty || activeSession != nil
    }

    var body: some View {
        if hasAnything {
            StudyHomeCard(
                title: "计时与恢复",
                subtitle: subtitle,
                systemImage: "timer",
                tint: StudyDesign.Colors.warning
            ) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                    if !interruptions.isEmpty {
                        interruptionSection
                    }
                    if !staleSessions.isEmpty {
                        staleSection
                    }
                    if let activeSession, interruptions.isEmpty {
                        activeSection(activeSession)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !interruptions.isEmpty { parts.append("\(interruptions.count) 段中断待确认") }
        if !staleSessions.isEmpty { parts.append("\(staleSessions.count) 条跨日遗留会话") }
        if activeSession != nil { parts.append("今天的计时进行中") }
        return parts.joined(separator: " · ")
    }

    // MARK: 中断确认

    private var interruptionSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text("中断确认")
                .font(StudyDesign.Typography.supporting.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            ForEach(interruptions, id: \.session.id) { entry in
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(entry.interruption.prompt)
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: StudyDesign.Spacing.tight) {
                        Button("这段时间在学") {
                            Task { _ = await store.resolveStudyInterruption(sessionID: entry.session.id, studiedDuringGap: true) }
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.success, prominence: .soft, size: .compact))

                        Button("没有学习") {
                            Task { _ = await store.resolveStudyInterruption(sessionID: entry.session.id, studiedDuringGap: false) }
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .soft, size: .compact))
                    }
                    .font(StudyDesign.Typography.supporting)
                }
                .padding(StudyDesign.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(StudyDesign.Colors.dataBackground)
                )
            }
        }
    }

    // MARK: 跨日遗留会话

    private var staleSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text("跨日遗留会话")
                .font(StudyDesign.Typography.supporting.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            Text("这些计时属于之前的 PJ 学习日，不会计入今天。可以结束（按它当天的范围归档）或放弃。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(staleSessions, id: \.id) { session in
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(staleTitle(session))
                        .font(StudyDesign.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(staleDetail(session))
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)

                    HStack(spacing: StudyDesign.Spacing.tight) {
                        Button("结束并归档") {
                            Task { _ = await store.finishStaleSession(sessionID: session.id) }
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .soft, size: .compact))

                        Button("放弃") {
                            Task { _ = await store.abandonStudySession(sessionID: session.id, reason: "跨日遗留会话，用户放弃") }
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .soft, size: .compact))
                    }
                    .font(StudyDesign.Typography.supporting)
                }
                .padding(StudyDesign.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(StudyDesign.Colors.dataBackground)
                )
            }
        }
    }

    private func staleTitle(_ session: StudySession) -> String {
        let minutes = session.effectiveMinutes(asOf: now, calendar: session.dayKey.timeZone.calendar ?? .current)
        return "\(session.dayKey.localDateString) 的会话 · 已记录 \(minutes) 分钟"
    }

    private func staleDetail(_ session: StudySession) -> String {
        var parts: [String] = ["状态：\(session.state.label)"]
        if session.progress.isPositive {
            parts.append("进度 \(session.progress.displayText)")
        } else {
            parts.append("没有记录进度")
        }
        if StudySessionEngineImpl.hasManualAdjustment(session) {
            parts.append("含手动修正")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 今天的会话

    private func activeSection(_ session: StudySession) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text("今天的计时")
                .font(StudyDesign.Typography.supporting.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            Text("状态：\(session.state.label) · 已记录 \(session.effectiveMinutes(asOf: now, calendar: nowCalendar)) 分钟")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            HStack(spacing: StudyDesign.Spacing.tight) {
                Button("记录进度") {
                    progressSessionID = session.id
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .soft, size: .compact))

                Button("手动修正时长") {
                    progressSessionID = session.id
                    targetMinutes = session.effectiveMinutes(asOf: now, calendar: nowCalendar)
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .soft, size: .compact))

                Button("放弃学习") {
                    Task { _ = await store.abandonStudySession(sessionID: session.id, reason: "用户在首页放弃") }
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .soft, size: .compact))
            }
            .font(StudyDesign.Typography.supporting)

            if progressSessionID == session.id {
                progressEditor(session)
            }
        }
    }

    private var nowCalendar: Calendar {
        store.snapshot.planningContext(now: now).calendar
    }

    private func progressEditor(_ session: StudySession) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            if let item = session.planItemID.flatMap({ id in
                store.snapshot.dailyPlans.flatMap(\.items).first { $0.id == id }
            }) {
                Text("按计划范围记录进度：计划 \(item.plannedScope.displayText)")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: StudyDesign.Spacing.tight) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { ratio in
                        let scope = StudyScope(
                            unit: item.plannedScope.unit,
                            amount: max(0.01, (item.plannedScope.amount * ratio).rounded()),
                            customUnitLabel: item.plannedScope.customUnitLabel
                        )
                        Button("\(Int(ratio * 100))%") {
                            progressSessionID = nil
                            Task { _ = await store.saveStudySessionProgress(sessionID: session.id, scope: scope) }
                        }
                        .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                    }
                }
                .font(StudyDesign.Typography.supporting)
            } else {
                Text("这条会话没有绑定计划项，无法按范围记录进度。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
            }

            Divider()

            Text("手动修正有效时长（保留原因）")
                .font(StudyDesign.Typography.supporting.weight(.semibold))
            Stepper(value: $targetMinutes, in: 0...600, step: 5) {
                Text("目标 \(targetMinutes) 分钟")
                    .font(StudyDesign.Typography.supporting)
            }
            TextField("修正原因", text: $adjustmentReason)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: StudyDesign.Spacing.tight) {
                Button("应用修正") {
                    let reason = adjustmentReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    progressSessionID = nil
                    Task {
                        _ = await store.adjustStudySessionDuration(
                            sessionID: session.id,
                            targetMinutes: targetMinutes,
                            reason: reason.isEmpty ? "用户修正" : reason
                        )
                    }
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .primary, size: .compact))

                Button("取消") { progressSessionID = nil }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
            }
            .font(StudyDesign.Typography.supporting)
        }
        .padding(StudyDesign.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                .fill(StudyDesign.Colors.dataBackground)
        )
    }
}

private extension TimeZone {
    /// 该时区对应的公历；用于把会话归属日换算成分钟数。
    var calendar: Calendar? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self
        return calendar
    }
}
