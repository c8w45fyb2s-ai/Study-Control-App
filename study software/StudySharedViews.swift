import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum StudyActionPillProminence {
    case primary
    case secondary
    case soft
}

enum StudyActionPillForegroundRole {
    /// Chooses the higher-contrast foreground for the resolved accent color.
    case automatic
    case lightContent
    case darkContent
}

enum StudyInputChromeSize {
    case compact
    case regular
    case spacious

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: return StudyDesign.Spacing.normal
        case .regular: return StudyDesign.Spacing.normal
        case .spacious: return StudyDesign.Spacing.roomy
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: return StudyDesign.Spacing.tight
        case .regular: return StudyDesign.Spacing.standard
        case .spacious: return StudyDesign.Spacing.normal
        }
    }

    var radius: CGFloat {
        switch self {
        case .compact: return StudyDesign.Radius.small
        case .regular: return StudyDesign.Radius.small
        case .spacious: return StudyDesign.Radius.medium
        }
    }
}

struct StudyInputChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var size: StudyInputChromeSize = .regular
    var tint: Color? = nil
    var isActive = false
    var includePadding = true

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, includePadding ? size.horizontalPadding : 0)
            .padding(.vertical, includePadding ? size.verticalPadding : 0)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                        .fill(StudyDesign.Colors.inputBackground)

                    if isActive {
                        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                            .fill(activeWash)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                    .strokeBorder(border, lineWidth: isActive ? 2 : 1)
            )
            .shadow(
                color: shadow,
                radius: isActive ? 7 : 4,
                y: isActive ? 2 : 1
            )
    }

    private var activeWash: Color {
        guard let tint, isActive else {
            return .clear
        }
        return tint.opacity(colorScheme == .dark ? 0.035 : 0.045)
    }

    private var border: Color {
        isActive ? (tint ?? StudyDesign.Colors.primary) : StudyDesign.Colors.inputHairline
    }

    private var shadow: Color {
        if let tint, isActive {
            return tint.opacity(colorScheme == .dark ? 0.055 : 0.075)
        }
        return StudyDesign.Shadow.card.color.opacity(isActive ? 0.86 : 0.52)
    }
}

extension View {
    func studyInputChrome(
        size: StudyInputChromeSize = .regular,
        tint: Color? = nil,
        isActive: Bool = false,
        includePadding: Bool = true
    ) -> some View {
        modifier(StudyInputChromeModifier(size: size, tint: tint, isActive: isActive, includePadding: includePadding))
    }
}

struct StudyPageHeader: View {
    let title: String
    let subtitle: String
    var icon: String
    var tint: Color = StudyDesign.Colors.primary
    var titleColor: Color = StudyDesign.Colors.labelPrimary
    var subtitleColor: Color = StudyDesign.Colors.labelSecondary
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(compact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
                .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(tint.opacity(0.28), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(compact ? StudyDesign.Typography.sectionTitle : StudyDesign.Typography.pageTitle)
                    .foregroundStyle(titleColor)
                Text(subtitle)
                    .font(compact ? .caption : StudyDesign.Typography.pageSubtitle)
                    .foregroundStyle(subtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct StudyMetaPillModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelPrimary)
            .lineLimit(1)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, 4)
            .background(StudyDesign.Colors.inputBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.42), lineWidth: 1)
            )
    }
}

extension View {
    func studyMetaPill(tint: Color = StudyDesign.Colors.secondary) -> some View {
        modifier(StudyMetaPillModifier(tint: tint))
    }
}

struct StudyDateControl: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @Binding var date: Date
    var displayedComponents: DatePickerComponents = .date

    private var mainDateText: String {
        if displayedComponents.contains(.hourAndMinute) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var detailText: String {
        if displayedComponents.contains(.hourAndMinute) {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private var relativeDateText: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        switch days {
        case ..<0:
            return "已过期 \(abs(days)) 天"
        case 0:
            return "今天"
        case 1:
            return "明天"
        case 2...6:
            return "\(days) 天后"
        default:
            return target.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private var relativeDateTint: Color {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        if days < 0 { return StudyDesign.Colors.danger }
        if days <= 1 { return tint }
        return StudyDesign.Colors.labelSecondary
    }

    var body: some View {
        ZStack {
            HStack(spacing: StudyDesign.Spacing.normal) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(StudyDesign.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                .fill(tint.opacity(0.10))
                        )
                    Image(systemName: icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: tint.opacity(0.08), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .lineLimit(1)

                        Text(relativeDateText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(relativeDateTint)
                            .lineLimit(1)
                            .padding(.horizontal, StudyDesign.Spacing.compact)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(StudyDesign.Colors.cardBackground))
                            .overlay(Capsule().stroke(relativeDateTint.opacity(0.14), lineWidth: 1))
                    }

                    Text(mainDateText)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
                    Text(detailText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(relativeDateTint)
                            .frame(width: 5, height: 5)
                        Image(systemName: "calendar.badge.clock")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
            }
            .padding(.leading, StudyDesign.Spacing.normal)
            .padding(.trailing, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.tight)
            .background {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.cardBackground,
                                StudyDesign.Colors.inputBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
            )
            .shadow(color: StudyDesign.Shadow.card.color.opacity(0.92), radius: 5, y: 2)

            DatePicker(title, selection: $date, displayedComponents: displayedComponents)
                .datePickerStyle(.compact)
                .labelsHidden()
                .opacity(0.015)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .help("选择\(title)：\(mainDateText)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(mainDateText)")
        .accessibilityValue(relativeDateText)
        .accessibilityHint("打开日期选择器")
        .accessibilityRepresentation {
            DatePicker(title, selection: $date, displayedComponents: displayedComponents)
        }
    }
}

enum StudyActionPillSize {
    case compact
    case regular

    var leadingPadding: CGFloat {
        switch self {
        case .compact: return 8
        case .regular: return 10
        }
    }

    var trailingPadding: CGFloat {
        switch self {
        case .compact: return 12
        case .regular: return 14
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: return 6
        case .regular: return 8
        }
    }

    var minHeight: CGFloat {
#if os(iOS)
        return 44
#else
        switch self {
        case .compact: return 30
        case .regular: return 34
        }
#endif
    }
}

enum StudyAccessibility {
    @MainActor
    static func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
#if os(macOS)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
#elseif canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: trimmed)
#endif
    }
}

struct StudyActionPillLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(StudyDesign.Colors.cardBackground.opacity(0.24))
                )

            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
        }
    }
}

struct StudyActionPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
#if os(macOS)
    @Environment(\.isFocused) private var isFocused
#endif

    var tint: Color = StudyDesign.Colors.primary
    var prominence: StudyActionPillProminence = .primary
    var size: StudyActionPillSize = .regular
    var minWidth: CGFloat? = nil
    var foregroundRole: StudyActionPillForegroundRole = .automatic

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .padding(.leading, size.leadingPadding)
            .padding(.trailing, size.trailingPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minWidth: minWidth, minHeight: size.minHeight)
            .background(
                Capsule()
                    .fill(background(configuration: configuration))
            )
            .overlay(
                Capsule()
                    .stroke(strokeColor(configuration: configuration), lineWidth: 1)
            )
            .shadow(
                color: shadowColor(configuration: configuration),
                radius: configuration.isPressed ? 4 : shadowRadius,
                y: configuration.isPressed ? 1 : shadowY
            )
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed && prominence == .primary ? -0.025 : 0)
            .clipShape(Capsule())
#if os(macOS)
            .overlay {
                if isFocused && isEnabled {
                    ZStack {
                        Capsule()
                            .stroke(.white.opacity(colorScheme == .dark ? 0.76 : 0.96), lineWidth: 5)
                        Capsule()
                            .stroke(StudyDesign.Colors.primary, lineWidth: 2)
                    }
                    .padding(-4)
                    .allowsHitTesting(false)
                }
            }
#endif
            .contentShape(Capsule())
            .animation(StudyDesign.Motion.animation(.fast), value: configuration.isPressed)
            .animation(StudyDesign.Motion.animation(.fast), value: isEnabled)
#if os(macOS)
            .animation(StudyDesign.Motion.animation(.fast), value: isFocused)
#endif
    }

    private var foregroundColor: Color {
        switch prominence {
        case .primary:
            return primaryForegroundColor
        case .secondary:
            return colorScheme == .dark ? .white.opacity(0.90) : StudyDesign.Colors.labelPrimary
        case .soft:
            return colorScheme == .dark ? .white.opacity(0.90) : StudyDesign.Colors.labelPrimary
        }
    }

    private var primaryForegroundColor: Color {
        switch foregroundRole {
        case .lightContent:
            return .white
        case .darkContent:
            return onAccentDark
        case .automatic:
            // Resolve dynamic semantic colours in both appearances and choose the
            // candidate with the stronger contrast. Bright warning/success fills in
            // dark mode often need dark text just as much as they do in light mode.
            return prefersDarkContent ? onAccentDark : .white
        }
    }

    private var prefersDarkContent: Bool {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme

        let accent = tint.resolve(in: environment)
        let alpha = Double(accent.opacity)
        let accentLuminance = relativeLuminance(
            red: Double(accent.linearRed),
            green: Double(accent.linearGreen),
            blue: Double(accent.linearBlue)
        )
        let surface = StudyDesign.Colors.pageBackground.resolve(in: environment)
        let surfaceLuminance = relativeLuminance(
            red: Double(surface.linearRed),
            green: Double(surface.linearGreen),
            blue: Double(surface.linearBlue)
        )
        let backgroundLuminance = accentLuminance * alpha + surfaceLuminance * (1 - alpha)

        let dark = onAccentDark.resolve(in: environment)
        let darkLuminance = relativeLuminance(
            red: Double(dark.linearRed),
            green: Double(dark.linearGreen),
            blue: Double(dark.linearBlue)
        )

        return contrastRatio(darkLuminance, backgroundLuminance)
            >= contrastRatio(1, backgroundLuminance)
    }

    private var onAccentDark: Color {
        Color(red: 0.055, green: 0.082, blue: 0.128)
    }

    private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func contrastRatio(_ lhs: Double, _ rhs: Double) -> Double {
        (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }

    private func background(configuration: Configuration) -> LinearGradient {
        switch prominence {
        case .primary:
            if colorScheme == .light {
                // An opaque fill makes the contrast decision deterministic on light surfaces.
                return LinearGradient(
                    colors: [tint, tint],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [
                    tint.opacity(configuration.isPressed ? primaryLeadingPressedOpacity : primaryLeadingOpacity),
                    tint.opacity(configuration.isPressed ? primaryTrailingPressedOpacity : primaryTrailingOpacity)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            return LinearGradient(
                colors: [
                    StudyDesign.Colors.cardBackground,
                    StudyDesign.Colors.dataBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .soft:
            return LinearGradient(
                colors: [
                    StudyDesign.Colors.elevatedBackground,
                    StudyDesign.Colors.dataBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func strokeColor(configuration: Configuration) -> Color {
        switch prominence {
        case .primary:
            return .white.opacity(configuration.isPressed ? 0.12 : 0.18)
        case .secondary:
            return tint.opacity(configuration.isPressed ? 0.22 : 0.14)
        case .soft:
            return tint.opacity(configuration.isPressed ? 0.14 : 0.08)
        }
    }

    private func shadowColor(configuration: Configuration) -> Color {
        guard isEnabled else { return .clear }
        switch prominence {
        case .primary:
            return tint.opacity(configuration.isPressed ? 0.08 : primaryShadowOpacity)
        case .secondary:
            return tint.opacity(configuration.isPressed ? 0.04 : secondaryShadowOpacity)
        case .soft:
            return StudyDesign.Shadow.card.color.opacity(configuration.isPressed ? 0.45 : softShadowOpacity)
        }
    }

    private var shadowRadius: CGFloat {
        switch size {
        case .compact: return colorScheme == .dark ? 7 : 6
        case .regular: return colorScheme == .dark ? 10 : 8
        }
    }

    private var shadowY: CGFloat {
        switch size {
        case .compact: return 3
        case .regular: return 4
        }
    }

    private var primaryLeadingOpacity: Double { colorScheme == .dark ? 0.78 : 0.94 }
    private var primaryTrailingOpacity: Double { colorScheme == .dark ? 0.62 : 0.82 }
    private var primaryLeadingPressedOpacity: Double { colorScheme == .dark ? 0.66 : 0.78 }
    private var primaryTrailingPressedOpacity: Double { colorScheme == .dark ? 0.52 : 0.66 }
    private var secondaryTrailingOpacity: Double { colorScheme == .dark ? 0.10 : 0.045 }
    private var secondaryTrailingPressedOpacity: Double { colorScheme == .dark ? 0.16 : 0.075 }
    private var primaryShadowOpacity: Double { colorScheme == .dark ? 0.16 : 0.14 }
    private var secondaryShadowOpacity: Double { colorScheme == .dark ? 0.08 : 0.07 }
    private var softShadowOpacity: Double { colorScheme == .dark ? 0.07 : 0.44 }
}

#if os(iOS)
private struct KeyboardDismissTapModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(KeyboardDismissTapView())
    }
}

private struct KeyboardDismissTapView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.install(on: view.window)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.install(on: view.window)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private weak var gesture: UITapGestureRecognizer?

        func install(on window: UIWindow?) {
            guard let window, installedWindow !== window else { return }
            uninstall()

            let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            window.addGestureRecognizer(gesture)

            installedWindow = window
            self.gesture = gesture
        }

        func uninstall() {
            if let gesture, let installedWindow {
                installedWindow.removeGestureRecognizer(gesture)
            }
            gesture = nil
            installedWindow = nil
        }

        @objc private func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is UITextField || view is UITextView || view is UISearchBar {
                    return false
                }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        deinit {
            uninstall()
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func dismissKeyboardOnTapOutside() -> some View {
#if os(iOS)
        modifier(KeyboardDismissTapModifier())
#else
        self
#endif
    }

    @ViewBuilder
    func iOSTouchTarget(_ size: CGFloat = 44) -> some View {
#if os(iOS)
        self.frame(minWidth: size, minHeight: size)
#else
        self
#endif
    }
}

struct SectionBlock<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            Text(title)
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(StudyDesign.Colors.surfaceFill)
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        }
    }
}
