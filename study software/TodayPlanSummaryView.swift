import SwiftUI

// MARK: - F 模块：今日概览
//
// 首页三个核心区域之一：模式、目标分钟数、已完成进度、一句安排原因。
// 只读取传入的展示模型（由 `StudyHomePresenter` 从真实快照算出），
// 不直接读写快照，也不发通知。

struct TodayPlanSummaryView: View {
    var overview: StudyHomeOverview
    /// 规划时区下的今天日期文案，例如 "9月23日 周三"。
    var dateText: String
    var onAdjustToday: () -> Void
    var onOpenPlan: () -> Void
    /// 打开「完整今日计划」（全部来源的任务 + 生成/重新评估 + 精力调整）。
    /// 可选：未提供时不渲染该按钮，旧调用点行为不变。
    var onOpenFullPlan: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { overview.intensity.tint }

    private var primaryMetricText: String {
        guard overview.targetMinutes > 0 else { return "未设定" }
        return "\(overview.targetMinutes) 分钟"
    }

    private var completedMetricText: String {
        guard overview.targetMinutes > 0 else { return "—" }
        return "\(overview.completedMinutes) 分钟"
    }

    var body: some View {
        StudyHomeCard(
            title: "今日概览",
            subtitle: dateText,
            systemImage: "sun.max",
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                FlowChips {
                    StudyPlanIntensityBadge(intensity: overview.intensity, tint: tint)
                    Text(overview.stateLabel)
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: StudyDesign.Spacing.wide) {
                    metric(title: "目标", value: primaryMetricText)
                    metric(title: "已完成", value: completedMetricText)
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    StudyHomeProgressBar(ratio: overview.progressRatio, tint: tint)
                    Text(summaryLine)
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: "text.bubble")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .accessibilityHidden(true)
                    Text(overview.reasonLine)
                        .font(StudyDesign.Typography.body)
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("安排原因：\(overview.reasonLine)")

                if let examLine = overview.examLine {
                    StudyHomeNoticeLine(
                        text: examLine,
                        systemImage: "flag.checkered",
                        tint: StudyDesign.Colors.warning
                    )
                }

                if let notice = overview.noticeLine {
                    StudyHomeNoticeLine(
                        text: notice,
                        systemImage: "info.circle",
                        tint: StudyDesign.Colors.info
                    )
                }

                HStack(spacing: StudyDesign.Spacing.tight) {
                    Button {
                        onAdjustToday()
                    } label: {
                        StudyActionPillLabel(title: "调整今天", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: tint, prominence: .soft, size: .compact))
                    .accessibilityLabel("调整今天")
                    .accessibilityHint("打开调整面板，把今天的任务压到轻量或保底")

                    Button {
                        onOpenPlan()
                    } label: {
                        StudyActionPillLabel(title: "查看计划", systemImage: "calendar")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                    .accessibilityLabel("查看计划页")
                    .accessibilityHint("打开计划页查看课程表、学习日历和全部任务")

                    if let onOpenFullPlan {
                        Button {
                            onOpenFullPlan()
                        } label: {
                            StudyActionPillLabel(title: "完整计划", systemImage: "list.bullet.rectangle")
                        }
                        .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                        .accessibilityLabel("查看完整今日计划")
                        .accessibilityHint("查看全部来源的计划项、放不下的任务，并可以重新评估或调整精力")
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.normal), value: overview.progressRatio)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(overview.accessibilityText)
    }

    /// 一行说明进度与完成口径：进度、还差多少，以及标准 / 保底 / 已学习的分账。
    private var summaryLine: String {
        var parts: [String] = [overview.progressText]
        if overview.remainingMinutes > 0, overview.targetMinutes > 0 {
            parts.append("还差 \(overview.remainingMinutes) 分钟")
        }
        parts.append(overview.completionCompactText)
        return parts.joined(separator: " · ")
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}
