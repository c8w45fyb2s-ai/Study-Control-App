import SwiftUI

// MARK: - StudyEmptyState

/// Quiet placeholder used when a learning surface has no content yet.
/// The visual language stays neutral so the next step, not decoration, carries
/// the emphasis.
struct StudyEmptyState: View {
    let title: String
    let subtitle: String
    /// Primary icon displayed inside the frosted circle (e.g. `graduationcap.fill`).
    let icon: String
    /// Small overlay icon tucked onto the bottom-right of the circle (e.g. `sparkles`).
    let accentIcon: String
    let accentTint: Color
    let actionLabel: String?
    let action: (() -> Void)?

    /// Convenience init — all params explicit, no default icons so call sites
    /// always intentionally pick the right pair.
    init(title: String,
         subtitle: String,
         icon: String,
         accentIcon: String = "sparkles",
         accentTint: Color = StudyDesign.Colors.labelSecondary,
         actionLabel: String? = nil,
         action: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accentIcon = accentIcon
        self.accentTint = accentTint
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.roomy) {
                emptyIcon

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let actionLabel, let action {
                EmptyStateActionButton(title: actionLabel, tint: accentTint, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(StudyDesign.Spacing.roomy)
        .padding(.horizontal, StudyDesign.Spacing.wide)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.elevated.radius * 0.72, y: StudyDesign.Shadow.card.y)
        .help("\(title)：\(subtitle)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(subtitle)")
    }

    private var emptyIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                .fill(StudyDesign.Colors.inputBackground)
                .frame(width: 72, height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                        .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
                )

            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .frame(width: 72, height: 72)

            Circle()
                .fill(StudyDesign.Colors.elevatedBackground)
                .frame(width: 25, height: 25)
                .overlay(
                    Image(systemName: accentIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accentTint)
                )
                .overlay(
                    Circle()
                        .stroke(accentTint.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: accentTint.opacity(0.055), radius: 6, y: 2)
                .offset(x: 5, y: 5)
        }
        .shadow(color: StudyDesign.Shadow.card.color,
                radius: StudyDesign.Shadow.card.radius,
                y: StudyDesign.Shadow.card.y)
        .accessibilityHidden(true)
    }
}

private struct EmptyStateActionButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StudyActionPillLabel(title: title, systemImage: "arrow.right")
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: tint, prominence: .secondary, minWidth: 118))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint("执行空状态推荐操作")
    }
}

// MARK: - Preview

#if DEBUG
struct StudyEmptyState_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            StudyEmptyState(
                title: "知识点为空",
                subtitle: "确认分析草稿后，知识点会自动沉淀在这里。",
                icon: "lightbulb.fill",
                accentIcon: "graduationcap.fill",
                actionLabel: "去导入资料",
                action: {}
            )

            StudyEmptyState(
                title: "今天暂时没有复习任务",
                subtitle: "导入错题或笔记并确认分析结果后，这里会出现今天要复习的内容。",
                icon: "calendar.badge.clock",
                accentIcon: "sun.max.fill",
                actionLabel: nil,
                action: nil
            )

            StudyEmptyState(
                title: "错题本为空",
                subtitle: "导入错题并确认分析结果后，这里会出现错题和错因。",
                icon: "xmark.circle.fill",
                accentIcon: "sparkles",
                actionLabel: "去导入资料",
                action: {}
            )
        }
    }
}
#endif
