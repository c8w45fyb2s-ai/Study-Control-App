import SwiftUI

// MARK: - F 模块：首页与一级导航的共用样式
//
// 只依赖既有 `StudyDesign` 设计系统（公共约束 10）：
// 颜色、间距、字体、圆角、阴影全部取自 `StudyDesign`，这里不新增调色板。
//
// 关于 Liquid Glass（导航要求）：
// - iOS 26 / macOS 26 上，系统 `TabView` 自带 Liquid Glass 外观，无需自绘；
// - 本文件里的 `studyHomeCardSurface` 在 iOS/macOS 26 及以上使用系统
//   `glassEffect`（SwiftUI 26 的 Liquid Glass API）渲染**卡片自身**的玻璃表面，
//   在更低版本、以及开启"减少透明度"时，回退到设计系统原有的不透明卡片底色。
//   回退实现**不是** Liquid Glass，代码与文案都不这样宣称。
// - `glassEffect` 的可用性用 `#available` 正确判断，deployment target 仍是 iOS 17 / macOS 14。

// MARK: - 卡片表面

/// 首页卡片容器：玻璃表面（新系统）或设计系统卡片底色（旧系统 / 减少透明度）。
struct StudyHomeCardSurface: ViewModifier {
    var tint: Color?
    var cornerRadius: CGFloat = StudyDesign.Radius.large
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            content
                .padding(StudyDesign.Spacing.normal)
                .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.12)) } ?? .regular, in: shape)
        } else {
            content
                .padding(StudyDesign.Spacing.normal)
                .background(StudyDesign.Colors.cardBackground, in: shape)
                .overlay(shape.stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))
                .shadow(
                    color: StudyDesign.Shadow.card.color,
                    radius: StudyDesign.Shadow.card.radius,
                    y: StudyDesign.Shadow.card.y
                )
        }
    }
}

extension View {
    /// 首页卡片外观。`tint` 只用于轻微的语义着色，不承担主要区分职责。
    func studyHomeCardSurface(tint: Color? = nil, cornerRadius: CGFloat = StudyDesign.Radius.large) -> some View {
        modifier(StudyHomeCardSurface(tint: tint, cornerRadius: cornerRadius))
    }
}

// MARK: - 卡片骨架

/// 带标题、图标与副标题的首页卡片。
struct StudyHomeCard<Content: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var tint: Color
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = StudyDesign.Colors.primary,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                Text(title)
                    .font(StudyDesign.Typography.cardTitle)
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studyHomeCardSurface(tint: tint)
    }
}

// MARK: - 计划强度徽标（文字优先）

/// 标准 / 轻量 / 保底：图标 + 文字 + 边框，不只靠颜色区分。
struct StudyPlanIntensityBadge: View {
    var intensity: StudyPlanIntensity
    var tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.micro) {
            Image(systemName: intensity.systemImage)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            Text(intensity.label)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.36), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("计划档位：\(intensity.fullLabel)")
    }
}

// MARK: - 小标签

/// 任务元信息标签（来源、时长、安排时间、档位）。
struct StudyHomeChip: View {
    var text: String
    var systemImage: String?
    var tint: Color = StudyDesign.Colors.labelSecondary

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.micro) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, 4)
        .background(StudyDesign.Colors.inputBackground, in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.24), lineWidth: 1))
    }
}

// MARK: - 提示行

/// 一行说明：未配置课表、未配置 API Key、引擎未接入、数据恢复提示等。
///
/// 这类信息只作为附注出现，**不隐藏**任何本地任务。
struct StudyHomeNoticeLine: View {
    var text: String
    var systemImage: String
    var tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(text)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .accessibilityHint("打开对应页面")
            }
        }
        .padding(StudyDesign.Spacing.tight)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 主按钮

/// 首页整页唯一的主按钮。
///
/// 视觉上比其余入口更突出；同一页面只在 `isPrimary == true` 时渲染一次。
struct StudyHomePrimaryButton: View {
    var action: StudyHomePrimaryAction
    var isEnabled: Bool = true
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Image(systemName: action.systemImage)
                    .font(.subheadline.weight(.bold))
                Text(action.label)
                    .font(.headline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StudyActionPillButtonStyle(prominence: .primary, size: .regular))
        .disabled(!isEnabled)
        .iOSTouchTarget(48)
        .accessibilityLabel(action.label)
        .accessibilityHint("在首页执行当前最重要的操作")
    }
}

// MARK: - 进度条

/// 今日完成进度。同时提供文字，颜色只是辅助。
struct StudyHomeProgressBar: View {
    var ratio: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, min(1, ratio)) * proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StudyDesign.Colors.surfaceFillDeep)
                Capsule()
                    .fill(tint)
                    .frame(width: width)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - 反馈

/// 首页唯一的反馈浮层内容（同一时刻只允许一个）。

// MARK: - 一级入口列表行

/// 「计划 / 资料 / 我的」三个入口共用的行样式。
///
/// 只描述外观；点击行为由外层的 `NavigationLink(value:)` 或 `Button` 决定。
struct StudyRootNavigationRow: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var tint: Color = StudyDesign.Colors.primary
    var countText: String?

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StudyDesign.Typography.body.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            if let countText {
                StudyHomeChip(text: countText, systemImage: nil, tint: tint)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, StudyDesign.Spacing.compact)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 语义色

extension StudyPlanIntensity {
    /// 档位语义色。文字始终与颜色同时出现，颜色只做辅助。
    var tint: Color {
        switch self {
        case .standard: return StudyDesign.Colors.success
        case .light: return StudyDesign.Colors.info
        case .minimum: return StudyDesign.Colors.warning
        case .rest: return StudyDesign.Colors.secondary
        case .none: return StudyDesign.Colors.labelSecondary
        }
    }

    var accessibilitySummary: String { fullLabel }
}
