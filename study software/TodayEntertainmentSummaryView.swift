import SwiftUI

// MARK: - F 模块：娱乐与休息
//
// 首页三个核心区域之三：最近的一条解锁条件或当前娱乐状态。
//
// 只读取真实规则与奖励记录：
// - 条件进度由 E 的 `RewardEvaluator` 提供（未接入时为 nil，界面不自行推算资格）；
// - 领取 / 开始 / 结束都交给 G 的统一入口，页面不直接改快照。

struct TodayEntertainmentSummaryView: View {
    var entertainment: StudyHomeEntertainment
    /// 娱乐操作是否为整页主按钮（已经有学习主按钮时为 false）。
    var isActionPrimary: Bool
    var onPerformAction: (StudyHomePrimaryAction) -> Void
    var onOpenRules: () -> Void

    private var tint: Color {
        switch entertainment.state {
        case .restTime: return StudyDesign.Colors.info
        case .noRules: return StudyDesign.Colors.labelSecondary
        case .locked: return StudyDesign.Colors.labelSecondary
        case .claimable: return StudyDesign.Colors.success
        case .claimed, .running: return StudyDesign.Colors.primary
        case .finished: return StudyDesign.Colors.success
        case .revoked: return StudyDesign.Colors.danger
        case .expired: return StudyDesign.Colors.labelSecondary
        case .undecidable: return StudyDesign.Colors.warning
        }
    }

    private var systemImage: String {
        switch entertainment.state {
        case .restTime: return "moon.zzz"
        case .noRules: return "gamecontroller"
        case .locked: return "lock"
        case .claimable: return "gift"
        case .claimed, .running: return "sparkles.tv"
        case .finished: return "checkmark.circle"
        case .revoked: return "xmark.circle"
        case .expired: return "clock"
        case .undecidable: return "questionmark.circle"
        }
    }

    var body: some View {
        StudyHomeCard(
            title: "娱乐与休息",
            subtitle: entertainment.ruleName,
            systemImage: systemImage,
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Text(entertainment.headline)
                    .font(StudyDesign.Typography.cardTitle)
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(entertainment.detail)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: StudyDesign.Spacing.micro) {
                    if let progressText = entertainment.progressText {
                        StudyHomeChip(text: "进度 \(progressText)", systemImage: "chart.bar", tint: tint)
                    }
                    if entertainment.rewardMinutes > 0 {
                        StudyHomeChip(text: "奖励 \(entertainment.rewardMinutes) 分钟", systemImage: "clock", tint: tint)
                    }
                    if entertainment.remainingMinutes > 0 {
                        StudyHomeChip(text: "剩余 \(entertainment.remainingMinutes) 分钟", systemImage: "hourglass")
                    }
                }

                if entertainment.action.isPrimary {
                    if isActionPrimary {
                        StudyHomePrimaryButton(action: entertainment.action, onTap: {
                            onPerformAction(entertainment.action)
                        })
                    } else {
                        Button {
                            onPerformAction(entertainment.action)
                        } label: {
                            StudyActionPillLabel(title: entertainment.action.label, systemImage: entertainment.action.systemImage)
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: tint, prominence: .soft, size: .compact))
                        .accessibilityLabel(entertainment.action.label)
                        .accessibilityHint("奖励已达标，可以领取或开始计时")
                    }
                }

                if entertainment.state == .noRules {
                    Button {
                        onOpenRules()
                    } label: {
                        StudyActionPillLabel(title: "设置娱乐规则", systemImage: "gamecontroller")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                    .accessibilityHint("打开「我的」页的娱乐规则设置")
                }

            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entertainment.accessibilityText)
    }
}
