import SwiftUI

// MARK: - F 模块：接下来做
//
// 首页三个核心区域之二：当前推荐任务、耗时、开始学习按钮，以及最多两项后续任务。
// 主按钮由 `StudyHomePresenter.pagePrimaryAction` 决定，整页只会渲染一个。

struct NextStudyTaskView: View {
    var nextSteps: StudyHomeNextSteps
    /// 整页唯一主按钮代表的操作。
    var primaryAction: StudyHomePrimaryAction
    var onPerformPrimary: (StudyHomePrimaryAction) -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onOpenSession: () -> Void
    var onOpenAllTasks: () -> Void
    var onOpenPlan: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { StudyDesign.Colors.primary }

    var body: some View {
        StudyHomeCard(
            title: "接下来做",
            subtitle: subtitle,
            systemImage: "play.circle",
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                if nextSteps.isStudying {
                    studyingBlock
                }

                if let current = nextSteps.current {
                    currentTaskBlock(current)
                } else if !nextSteps.isStudying {
                    emptyBlock
                }

                if !nextSteps.upcoming.isEmpty {
                    upcomingBlock
                }

                if primaryAction.isPrimary {
                    StudyHomePrimaryButton(action: primaryAction, onTap: {
                        onPerformPrimary(primaryAction)
                    })
                }

                if nextSteps.remainingCount > 0 || nextSteps.isStudying {
                    Button {
                        onOpenAllTasks()
                    } label: {
                        StudyActionPillLabel(title: "查看全部任务", systemImage: "list.bullet")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                    .accessibilityLabel("查看全部任务")
                    .accessibilityHint("打开计划页的任务列表")
                }
            }
        }
    }

    private var subtitle: String {
        if nextSteps.remainingCount > 0 {
            return "还有 \(nextSteps.remainingCount) 项没完成"
        }
        return "当前没有待开始的任务"
    }

    // MARK: 正在学习

    private var studyingBlock: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            if let status = nextSteps.sessionStatusText {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: nextSteps.isPaused ? "pause.circle.fill" : "timer")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(nextSteps.isPaused ? StudyDesign.Colors.warning : StudyDesign.Colors.success)
                        .accessibilityHidden(true)
                    Text(status)
                        .font(StudyDesign.Typography.body)
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                if nextSteps.isPaused {
                    Button {
                        onResume()
                    } label: {
                        StudyActionPillLabel(title: "继续", systemImage: "play.fill")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .secondary, size: .compact))
                    .accessibilityHint("继续计时")
                } else {
                    Button {
                        onPause()
                    } label: {
                        StudyActionPillLabel(title: "暂停", systemImage: "pause.fill")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .secondary, size: .compact))
                    .accessibilityHint("暂停计时，已用时间会保留")
                }

                Button {
                    onOpenSession()
                } label: {
                    StudyActionPillLabel(title: "打开学习界面", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                .accessibilityHint("打开学习计时与进度记录界面")
            }
        }
        .padding(StudyDesign.Spacing.tight)
        .background(
            (nextSteps.isPaused ? StudyDesign.Colors.warning : StudyDesign.Colors.success).opacity(0.08),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
    }

    // MARK: 当前任务

    private func currentTaskBlock(_ task: StudyHomeTask) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.tight) {
                Text(task.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if task.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.warning)
                        .accessibilityLabel("已固定")
                }

                Spacer(minLength: 0)
            }

            FlowChips {
                StudyHomeChip(text: task.sourceLabel, systemImage: "tray.full")
                StudyHomeChip(text: "预计 \(task.estimatedMinutes) 分钟", systemImage: "clock")
                StudyHomeChip(text: task.scheduleText, systemImage: "calendar")
                if task.statusLabel != "待开始" {
                    StudyHomeChip(text: task.statusLabel, systemImage: "circle.dashed")
                }
                if let tier = task.tierLabel {
                    StudyHomeChip(text: tier, systemImage: "checkmark.seal", tint: StudyDesign.Colors.success)
                }
            }

            if let dueText = task.dueText {
                Text(dueText)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前推荐任务。\(task.accessibilityText)")
        .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast), value: task.id)
    }

    // MARK: 后续任务（最多两项）

    private var upcomingBlock: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("之后")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            ForEach(nextSteps.upcoming) { task in
                HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(StudyDesign.Typography.body)
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            .lineLimit(1)
                        Text("\(task.sourceLabel) · 预计 \(task.estimatedMinutes) 分钟 · \(task.scheduleText)")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("后续任务。\(task.accessibilityText)")
            }
        }
    }

    // MARK: 空状态

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text(nextSteps.emptyTitle)
                .font(StudyDesign.Typography.cardTitle)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
            Text(nextSteps.emptySubtitle)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onOpenPlan()
            } label: {
                StudyActionPillLabel(title: "去计划页", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
            .accessibilityHint("打开计划页生成或添加任务")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 自动换行的标签行

/// 简单换行布局：在大字体下标签会自然换到下一行，而不是压缩文字。
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.micro) { content }
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) { content }
        }
    }
}
