import SwiftUI

// MARK: - InfoCard

/// Metric/stat card that replaces `MetricTile`. Displays a large value,
/// a compact semantic icon, and optional supporting context.
///
/// Visual: neutral dossier surface + compact semantic icon.
/// Fixed minimum height keeps neighbouring cards aligned even as numbers change.
struct InfoCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = StudyDesign.Colors.info
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.compact) {
                InteractiveCardIcon(icon: icon, tint: tint, size: 38, font: .title3.weight(.semibold))

                Spacer(minLength: StudyDesign.Spacing.compact)
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(value)
                    .font(.system(size: 33, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                    .animation(StudyDesign.Motion.animation(.normal), value: value)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(minHeight: 112, alignment: .topLeading)
        .padding(StudyDesign.Spacing.normal)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .studyCardChrome(radius: StudyDesign.Radius.small)
        .help(accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if let subtitle {
            return "\(title)：\(value)，\(subtitle)"
        }
        return "\(title)：\(value)"
    }
}

// MARK: - ActionCard

/// CTA card that guides the user to the next step. The card stays mostly
/// neutral; semantic emphasis is carried by the icon and button.
struct ActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    var tint: Color = StudyDesign.Colors.info
    let actionTitle: String
    var actionHint: String? = nil
    let action: () -> Void

    private var resolvedActionHint: String {
        actionHint ?? actionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                InteractiveCardIcon(icon: icon, tint: tint, size: 40, font: .title3.weight(.semibold))

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer(minLength: StudyDesign.Spacing.compact)

                Button(action: action) {
                    StudyActionPillLabel(title: actionTitle, systemImage: "arrow.right")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: tint, minWidth: 112))
                .help(resolvedActionHint)
                .accessibilityLabel(actionTitle)
                .accessibilityHint(resolvedActionHint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .studyCardChrome(radius: StudyDesign.Radius.medium)
        .help("\(title)：\(subtitle)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

// MARK: - ListCard

/// Uniform wrapper for list items (knowledge points, mistakes, review tasks,
/// diagnostic entries, etc.).
///
/// Visual: one calm neutral surface, quiet hairline, and standard inner padding.
struct ListCard<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(StudyDesign.Spacing.normal)
        }
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(StudyDesign.Colors.elevatedBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(listStroke, lineWidth: 1)
        )
        .studyCardChrome(radius: StudyDesign.Radius.small)
    }

    private var listStroke: Color {
        if let tint {
            return tint.opacity(0.42)
        }
        return StudyDesign.Colors.accentHairline
    }
}

// MARK: - Card Interaction Helpers

private struct InteractiveCardIcon: View {
    let icon: String
    let tint: Color
    let size: CGFloat
    let font: Font

    var body: some View {
        Image(systemName: icon)
            .font(font)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(StudyDesign.Colors.dataBackground)
                    .overlay(Circle().fill(tint.opacity(0.045)))
            )
            .overlay(
                Circle()
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct StudyCardChromeModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(
                color: StudyDesign.Shadow.card.color.opacity(0.56),
                radius: 4,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

private extension View {
    func studyCardChrome(radius: CGFloat) -> some View {
        modifier(StudyCardChromeModifier(radius: radius))
    }
}

// MARK: - SettingsCard

/// A settings-page card that pairs a titled icon with stacked controls.
/// Replaces the local `cardPanel()` helper in SettingsView so the
/// card vocabulary stays in one file.
struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Gradients.dataSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .help(title)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - InstructionCard

/// Compact hint card for inline guidance — lighter than `StudyEmptyState`,
/// designed for places where a full-page empty state would be too loud
/// (e.g. the "选择资料" hint inside the import flow).
struct InstructionCard: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Gradients.featureSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .help("\(title)：\(subtitle)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

// MARK: - Preview (debug only)

#if DEBUG
struct StudyCards_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: StudyDesign.Spacing.roomy) {
                // ── InfoCards ──────────────────────────────────
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: StudyDesign.Spacing.normal)],
                          spacing: StudyDesign.Spacing.normal) {
                    InfoCard(title: "连续学习", value: "7 天", icon: "flame.fill",
                            tint: StudyDesign.Colors.warning)
                    InfoCard(title: "待复习", value: "3", icon: "calendar.badge.clock",
                            tint: StudyDesign.Colors.warning, subtitle: "2 项已过期")
                    InfoCard(title: "知识点", value: "42", icon: "lightbulb",
                            tint: StudyDesign.Colors.info)
                    InfoCard(title: "错题", value: "15", icon: "xmark.circle",
                            tint: StudyDesign.Colors.danger)
                }

                // ── ActionCard ─────────────────────────────────
                ActionCard(
                    title: "开始今日复习",
                    subtitle: "3 项待处理，按优先级和到期时间排列",
                    icon: "play.circle",
                    actionTitle: "开始复习",
                    action: {}
                )

                // ── ListCards ──────────────────────────────────
                ListCard(tint: StudyDesign.Colors.danger) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        Text("样本复习任务").font(.headline)
                        Text("已过期 · 优先级 2").font(.caption).foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                }

                ListCard {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        Text("知识点：SwiftUI 状态管理").font(.headline)
                        Text("科目：iOS 开发 · 掌握度 45%").font(.caption).foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
        }
    }
}
#endif
