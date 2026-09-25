import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - StudyDesign Token Catalogue

/// Single source of truth for every visual constant in the app.
/// Replace scattered `.quaternary.opacity(…)`, hardcoded `8/12/16/24`,
/// and bare `Color.accentColor` with tokens from this namespace.
///
/// **Note:** AccentColor.colorset is indigo (≈ primary).
/// Reserve `StudyDesign.Colors.primary` for true primary actions, progress, and selected states;
/// use neutral surfaces and semantic colours for ordinary cards and status UI.
///
/// **Coverage:** cards, empty states, chart fills, banners, filter controls,
/// mastery badges, overdue indicators, chat bubbles, import review cards,
/// metric tiles — every repeated pattern in the codebase.
enum StudyDesign {

    // MARK: - Colours

    enum Colors {
#if os(macOS)
        private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let matched = appearance.bestMatch(from: [.darkAqua, .aqua])
                return matched == .darkAqua ? dark : light
            })
        }
#elseif canImport(UIKit)
        private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            })
        }
#endif

        // ── Brand ────────────────────────────────────────────────
        /// Indigo / blue-purple — primary action colour, progress tints, active states.
        static let primary: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.192157, green: 0.341176, blue: 0.909804, alpha: 1),
                dark: NSColor(red: 0.365, green: 0.310, blue: 0.860, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.192157, green: 0.341176, blue: 0.909804, alpha: 1),
                dark: UIColor(red: 0.365, green: 0.310, blue: 0.860, alpha: 1)
            )
#else
            Color(red: 0.192157, green: 0.341176, blue: 0.909804)
#endif
        }()
        /// Cyan / sky-blue — complementary accent for secondary actions, links.
        static let secondary: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.000000, green: 0.435294, blue: 0.760784, alpha: 1),
                dark: NSColor(red: 0.250, green: 0.600, blue: 0.830, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.000000, green: 0.435294, blue: 0.760784, alpha: 1),
                dark: UIColor(red: 0.250, green: 0.600, blue: 0.830, alpha: 1)
            )
#else
            Color(red: 0.000000, green: 0.435294, blue: 0.760784)
#endif
        }()

        // ── Semantic ─────────────────────────────────────────────
#if os(macOS)
        static let success = adaptiveColor(
            light: NSColor(red: 0.039216, green: 0.478431, blue: 0.352941, alpha: 1),
            dark: NSColor(red: 0.300, green: 0.700, blue: 0.520, alpha: 1)
        )
        static let warning = adaptiveColor(
            light: NSColor(red: 0.639216, green: 0.325490, blue: 0.000000, alpha: 1),
            dark: NSColor(red: 1.000, green: 0.580, blue: 0.170, alpha: 1)
        )
        static let danger = adaptiveColor(
            light: NSColor(red: 0.800, green: 0.180, blue: 0.300, alpha: 1),
            dark: NSColor(red: 1.000, green: 0.290, blue: 0.340, alpha: 1)
        )
        static let info = adaptiveColor(
            light: NSColor(red: 0.080, green: 0.410, blue: 0.920, alpha: 1),
            dark: NSColor(red: 0.260, green: 0.560, blue: 0.820, alpha: 1)
        )
#elseif canImport(UIKit)
        static let success = adaptiveColor(
            light: UIColor(red: 0.039216, green: 0.478431, blue: 0.352941, alpha: 1),
            dark: UIColor(red: 0.300, green: 0.700, blue: 0.520, alpha: 1)
        )
        static let warning = adaptiveColor(
            light: UIColor(red: 0.639216, green: 0.325490, blue: 0.000000, alpha: 1),
            dark: UIColor(red: 1.000, green: 0.580, blue: 0.170, alpha: 1)
        )
        static let danger = adaptiveColor(
            light: UIColor(red: 0.800, green: 0.180, blue: 0.300, alpha: 1),
            dark: UIColor(red: 1.000, green: 0.290, blue: 0.340, alpha: 1)
        )
        static let info = adaptiveColor(
            light: UIColor(red: 0.080, green: 0.410, blue: 0.920, alpha: 1),
            dark: UIColor(red: 0.260, green: 0.560, blue: 0.820, alpha: 1)
        )
#else
        static let success = Color(red: 0.039216, green: 0.478431, blue: 0.352941)
        static let warning = Color(red: 0.639216, green: 0.325490, blue: 0.000000)
        static let danger  = Color(red: 0.800, green: 0.180, blue: 0.300)
        static let info    = Color(red: 0.080, green: 0.410, blue: 0.920)
#endif

        // ── Surfaces (adapt to light / dark) ─────────────────────
#if os(macOS)
        static let pageBackground  = adaptiveColor(
            light: NSColor(red: 0.964706, green: 0.968627, blue: 0.984314, alpha: 1),
            dark: NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
        static let cardBackground  = adaptiveColor(
            light: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            dark: NSColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1)
        )
        static let chromeBackground = adaptiveColor(
            light: NSColor(red: 0.945098, green: 0.952941, blue: 0.968627, alpha: 1),
            dark: NSColor(red: 0.067, green: 0.071, blue: 0.082, alpha: 0.98)
        )
        static let sidebarBackground = adaptiveColor(
            light: NSColor(red: 0.945098, green: 0.952941, blue: 0.968627, alpha: 1),
            dark: NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
        static let contentBackground = adaptiveColor(
            light: NSColor(red: 0.964706, green: 0.968627, blue: 0.984314, alpha: 1),
            dark: NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
        static let elevatedBackground = adaptiveColor(
            light: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            dark: NSColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1)
        )
        /// Opaque feature stop so nested cards never inherit an unintended page tint.
        static let featureSurfaceEnd = adaptiveColor(
            light: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
                dark: NSColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1)
        )
        static let featureBackground = adaptiveColor(
            light: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            dark: NSColor(red: 0.078, green: 0.084, blue: 0.100, alpha: 1)
        )
        static let dataBackground = adaptiveColor(
            light: NSColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
            dark: NSColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1)
        )
#elseif canImport(UIKit)
        static let pageBackground  = adaptiveColor(
            light: UIColor(red: 0.964706, green: 0.968627, blue: 0.984314, alpha: 1),
            dark: UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
        static let cardBackground  = adaptiveColor(
            light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            dark: UIColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1)
        )
        static let chromeBackground = adaptiveColor(
            light: UIColor(red: 0.945098, green: 0.952941, blue: 0.968627, alpha: 1),
            dark: UIColor(red: 0.067, green: 0.071, blue: 0.082, alpha: 0.98)
        )
        static let sidebarBackground = adaptiveColor(
            light: UIColor(red: 0.945098, green: 0.952941, blue: 0.968627, alpha: 1),
            dark: UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
        static let contentBackground = adaptiveColor(
            light: UIColor(red: 0.964706, green: 0.968627, blue: 0.984314, alpha: 1),
            dark: UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
        static let elevatedBackground = adaptiveColor(
            light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            dark: UIColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1)
        )
        /// Opaque in light mode so feature cards stay flat; preserves the existing translucent dark stop.
        static let featureSurfaceEnd = adaptiveColor(
            light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
                dark: UIColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1)
        )
        static let featureBackground = adaptiveColor(
            light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
            dark: UIColor(red: 0.078, green: 0.084, blue: 0.100, alpha: 1)
        )
        static let dataBackground = adaptiveColor(
            light: UIColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
            dark: UIColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1)
        )
#else
        static let pageBackground  = Color.secondary.opacity(0.06)
        static let cardBackground  = Color.secondary.opacity(0.08)
        static let chromeBackground = Color.secondary.opacity(0.07)
        static let sidebarBackground = chromeBackground
        static let contentBackground = pageBackground
        static let elevatedBackground = cardBackground
        static let featureSurfaceEnd = elevatedBackground
        static let featureBackground = cardBackground
        static let dataBackground = inputBackground
#endif

        // ── Neutral overlay fills ────────────────────────────────
        /// Standard neutral surface for ordinary cards, sections, empty states, and document content.
        static let surfaceFill: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
                dark: NSColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1),
                dark: UIColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1)
            )
#else
            Color.secondary.opacity(0.08)
#endif
        }()
        /// Slightly stronger neutral surface for dense metric tiles and selected content blocks.
        static let surfaceFillDeep: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
                dark: NSColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
                dark: UIColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1)
            )
#else
            Color.secondary.opacity(0.12)
#endif
        }()
        /// Quiet neutral surface for filter controls, subtle rows, chart wells, and assistant bubbles.
        static let surfaceFillLight: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
                dark: NSColor(red: 0.035, green: 0.039, blue: 0.051, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
                dark: UIColor(red: 0.035, green: 0.039, blue: 0.051, alpha: 1)
            )
#else
            Color.secondary.opacity(0.055)
#endif
        }()
        /// Recessed input/control well. Slightly denser than cards so fields do not look washed out.
        static let inputBackground: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
                dark: NSColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.933333, green: 0.949020, blue: 0.968627, alpha: 1),
                dark: UIColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1)
            )
#else
            Color.secondary.opacity(0.075)
#endif
        }()
        /// Inner highlight for input/control wells; keeps borders readable without returning to raw black.
        static let inputHairline: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.455, green: 0.506, blue: 0.596, alpha: 1),
                dark: NSColor(red: 0.455, green: 0.486, blue: 0.560, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.455, green: 0.506, blue: 0.596, alpha: 1),
                dark: UIColor(red: 0.455, green: 0.486, blue: 0.560, alpha: 1)
            )
#else
            Color.secondary.opacity(0.20)
#endif
        }()

        // ── Accent overlays ─────────────────────────────────────
        /// Default hairline for ordinary cards. Keep neutral so brand colour is reserved for active states.
        static let accentHairline: Color = {
#if os(macOS)
            adaptiveColor(
                light: NSColor(red: 0.847059, green: 0.870588, blue: 0.909804, alpha: 1),
                dark: NSColor(red: 0.141, green: 0.149, blue: 0.169, alpha: 1)
            )
#elseif canImport(UIKit)
            adaptiveColor(
                light: UIColor(red: 0.847059, green: 0.870588, blue: 0.909804, alpha: 1),
                dark: UIColor(red: 0.141, green: 0.149, blue: 0.169, alpha: 1)
            )
#else
            Color.secondary.opacity(0.16)
#endif
        }()
        /// Neutral icon/tag background; brand colour is reserved for selected or primary actions.
        static let accentSubtle    = Colors.inputBackground
        /// Slightly stronger neutral active-step fill that does not tint whole panels.
        static let accentMedium    = Colors.cardBackground
        /// Neutral file-review stroke.
        static let accentStroke    = Colors.inputHairline

        // ── Semantic overlays ────────────────────────────────────
        /// Chat user bubble fill.
        static let userBubbleFill  = inputBackground
        /// Overdue badge / row background.
        static let dangerSubtle    = danger.opacity(0.09)
        /// Overdue row background (lighter variant).
        static let dangerSubtleLight = danger.opacity(0.055)
        /// Overdue row stroke.
        static let dangerStroke    = danger.opacity(0.46)
        /// Default (non-overdue) task row background.
        static let rowFill         = surfaceFill
        /// Mastery-level badge background — call as `masteryBadge(masteryLevel.color)`.
        static func masteryBadge(_ color: Color) -> Color { color.opacity(0.11) }

        // ── Content ──────────────────────────────────────────────
#if os(macOS)
        static let labelPrimary = adaptiveColor(
            light: NSColor(red: 0.090196, green: 0.125490, blue: 0.200000, alpha: 1),
            dark: NSColor(red: 0.957, green: 0.957, blue: 0.965, alpha: 1)
        )
        static let labelSecondary = adaptiveColor(
            light: NSColor(red: 0.337255, green: 0.380392, blue: 0.462745, alpha: 1),
            dark: NSColor(red: 0.643, green: 0.643, blue: 0.667, alpha: 1)
        )
        static let labelTertiary = adaptiveColor(
            light: NSColor(red: 0.349020, green: 0.403922, blue: 0.482353, alpha: 1),
            dark: NSColor(red: 0.650, green: 0.670, blue: 0.720, alpha: 1)
        )
#elseif canImport(UIKit)
        static let labelPrimary = adaptiveColor(
            light: UIColor(red: 0.090196, green: 0.125490, blue: 0.200000, alpha: 1),
            dark: UIColor(red: 0.957, green: 0.957, blue: 0.965, alpha: 1)
        )
        static let labelSecondary = adaptiveColor(
            light: UIColor(red: 0.337255, green: 0.380392, blue: 0.462745, alpha: 1),
            dark: UIColor(red: 0.643, green: 0.643, blue: 0.667, alpha: 1)
        )
        static let labelTertiary = adaptiveColor(
            light: UIColor(red: 0.349020, green: 0.403922, blue: 0.482353, alpha: 1),
            dark: UIColor(red: 0.650, green: 0.670, blue: 0.720, alpha: 1)
        )
#else
        static let labelPrimary    = Color.primary
        static let labelSecondary  = Color.secondary
        static let labelTertiary   = Color.secondary.opacity(0.75)
#endif

        // ── Depth ───────────────────────────────────────────────
#if os(macOS)
        /// Neutral elevation tint. Avoid raw black in light mode so surfaces feel weighted, not dirty.
        static let shadowNeutral = adaptiveColor(
            light: NSColor(red: 0.150, green: 0.210, blue: 0.300, alpha: 1),
            dark: NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
#elseif canImport(UIKit)
        /// Neutral elevation tint. Avoid raw black in light mode so surfaces feel weighted, not dirty.
        static let shadowNeutral = adaptiveColor(
            light: UIColor(red: 0.150, green: 0.210, blue: 0.300, alpha: 1),
            dark: UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1)
        )
#else
        static let shadowNeutral = labelPrimary
#endif
    }

    // MARK: - Motion

    /// Unified animation tokens so every transition shares the same "feel."
    /// All durations respect `Reduce Motion` — when the system accessibility
    /// setting is enabled, animations are replaced with a zero-duration fade
    /// or removed entirely.
    enum Motion {
        // ── Durations (seconds) ───────────────────────────────
        /// Button taps, icon feedback, tiny state toggles.
        static let fast: Double = 0.18
        /// Card transitions, filter/sort switches, disclosure expand.
        static let normal: Double = 0.28
        /// Mastery chart bars, review-complete pop, quality-picker reveal.
        static let spring: Double = 0.40
        /// Hero banner entrance, dashboard first-load, key data numbers.
        static let heroReveal: Double = 0.70

        // ── Animation factory ─────────────────────────────────
        /// Returns the correct animation for the given token, automatically
        /// degraded when Reduce Motion is enabled.
        static func animation(_ token: MotionToken) -> Animation {
            guard !reduceMotionEnabled else { return .linear(duration: 0.01) }
            switch token {
            case .fast, .normal:
                return .interactiveSpring(response: token.duration, dampingFraction: 0.78)
            case .spring:
                return .spring(response: token.duration, dampingFraction: 0.72)
            case .heroReveal:
                return .spring(response: token.duration, dampingFraction: 0.65)
            }
        }

        /// Convenience for `withAnimation(Motion.animation(.fast)) { … }`.
        static func animate(_ token: MotionToken, _ body: () -> Void) {
            withAnimation(animation(token), body)
        }

        /// Build the same animation as a View modifier.
        static func modifier(_ token: MotionToken, value: some Hashable) -> some ViewModifier {
            _MotionViewModifier(token: token, value: value)
        }

        // ── Reduce Motion ─────────────────────────────────────
        private static var reduceMotionEnabled: Bool {
#if os(macOS)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#elseif canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled
#else
            false
#endif
        }
    }

    enum MotionToken: Hashable {
        case fast, normal, spring, heroReveal

        var duration: Double {
            switch self {
            case .fast:       return Motion.fast
            case .normal:     return Motion.normal
            case .spring:     return Motion.spring
            case .heroReveal: return Motion.heroReveal
            }
        }
    }

    // MARK: - Typography

    /// Shared type roles keep page and card hierarchy consistent across features.
    enum Typography {
        static let pageTitle: Font = .title.weight(.bold)
        static let pageSubtitle: Font = .subheadline
        static let sectionTitle: Font = .title3.weight(.semibold)
        static let cardTitle: Font = .headline.weight(.semibold)
        static let body: Font = .body
        static let supporting: Font = .caption
        static let metric: Font = .system(size: 28, weight: .bold, design: .rounded)
    }

    // MARK: - Layout

    enum Layout {
        static let contentMaxWidth: CGFloat = 1_120
        static let readingMaxWidth: CGFloat = 780
    }

    // MARK: - Corner Radii

    enum Radius {
        /// Bar-chart bars, tiny clips.         (was: `4`)
        static let micro: CGFloat   = 4
        /// Rounded bar corners (charts).        (was: `6`)
        static let compact: CGFloat = 6
        /// Dominant card / row / block radius.  (was: `8`)
        static let small: CGFloat   = 8
        /// Elevated sheets, larger panels.      (new)
        static let medium: CGFloat  = 12
        /// Chat bubbles.                        (was: `14`)
        static let chatBubble: CGFloat = 14
        /// Modal sheets, onboarding cards.      (new)
        static let large: CGFloat   = 16
        /// Use `Capsule()` shape instead.
        static let pill: CGFloat    = 9999   // sentinel — use Capsule() in code
    }

    // MARK: - Spacing

    enum Spacing {
        /// Stack grid, tiny gutters.           (was: `2, 3`)
        static let micro: CGFloat    = 4
        /// Compact HStack / VStack gaps.       (was: `4, 5, 6`)
        static let compact: CGFloat  = 6
        /// Default tight padding, small gaps.  (was: `8`)
        static let tight: CGFloat    = 8
        /// Standard H/VStack spacing.          (was: `10`)
        static let standard: CGFloat = 10
        /// Normal paragraph / card padding.     (was: `12`)
        static let normal: CGFloat   = 12
        /// Chat bubble inner padding.          (was: `14`)
        static let chatInner: CGFloat = 14
        /// Roomier block gutters.              (was: `16, 18`)
        static let roomy: CGFloat    = 16
        /// Relaxed outer padding.              (was: `20`)
        static let relaxed: CGFloat  = 20
        /// Full-page horizontal padding.        (was: `24`)
        static let wide: CGFloat     = 24
        /// Section-to-section vertical gap.     (was: `28`)
        static let section: CGFloat  = 28
        /// Onboarding page padding.            (was: `36, 40`)
        static let onboardingX: CGFloat = 40
        static let onboardingY: CGFloat = 36

        /// Convenience: the standard `EdgeInsets` for a card.
        static let cardInsets = EdgeInsets(
            top: normal, leading: normal,
            bottom: normal, trailing: normal
        )
    }

    // MARK: - Shadows

    enum Shadow {
        /// Light card elevation (new — replaces the absence of any shadow).
        static let card: (color: Color, radius: CGFloat, y: CGFloat) =
            (Colors.shadowNeutral.opacity(0.055), radius: 8, y: 2)

        /// Elevated / hover sheet shadow (new).
        static let elevated: (color: Color, radius: CGFloat, y: CGFloat) =
            (Colors.shadowNeutral.opacity(0.090), radius: 18, y: 6)

        /// Applies `card` shadow to a view.
        @ViewBuilder
        static func cardShadow<T: View>(_ content: T) -> some View {
            content.shadow(color: card.color,
                           radius: card.radius,
                           y: card.y)
        }

        /// Applies `elevated` shadow to a view.
        @ViewBuilder
        static func elevatedShadow<T: View>(_ content: T) -> some View {
            content.shadow(color: elevated.color,
                           radius: elevated.radius,
                           y: elevated.y)
        }
    }

    // MARK: - Gradients

    enum Gradients {
        /// Primary brand gradient (indigo → cyan).
        static let brand = LinearGradient(
            gradient: Gradient(colors: [Colors.primary, Colors.secondary]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Quiet charcoal wash for hero / empty-state backgrounds.
        static let brandWash = LinearGradient(
            gradient: Gradient(colors: [
                Colors.cardBackground,
                Colors.featureBackground
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Default raised panel surface for cards and section containers.
        static let panelSurface = LinearGradient(
            gradient: Gradient(colors: [
                Colors.cardBackground,
                Colors.elevatedBackground
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Slightly richer surface for headers, empty states, and feature blocks.
        static let featureSurface = LinearGradient(
            gradient: Gradient(colors: [
                Colors.cardBackground,
                Colors.featureSurfaceEnd
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Recessed surface for metrics, charts, inputs, and compact data wells.
        static let dataSurface = LinearGradient(
            gradient: Gradient(colors: [
                Colors.dataBackground,
                Colors.inputBackground
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Stable chrome fill for sidebars, docks, and persistent bars.
        static let chromeSurface = LinearGradient(
            gradient: Gradient(colors: [
                Colors.chromeBackground,
                Colors.sidebarBackground
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// App-level page backdrop. Dark mode stays close to true black.
        static let pageBackdrop = LinearGradient(
            gradient: Gradient(colors: [
                Colors.pageBackground,
                Colors.contentBackground,
                Colors.pageBackground
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// Subtle semantic rail for cards that need emphasis without turning into brand surfaces.
        static func semanticWash(_ color: Color) -> LinearGradient {
            LinearGradient(
                gradient: Gradient(colors: [
                    color.opacity(0.085),
                    Color.clear
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        /// Mastery chart bar gradient (good → great).
        static func masteryBar(_ color: Color) -> LinearGradient {
            LinearGradient(
                gradient: Gradient(colors: [color.opacity(0.46), color.opacity(0.78)]),
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }

    // MARK: - Chart helpers

    /// Neutral empty bar on weekly and mastery charts.
    static let chartEmptyBarFill = Colors.surfaceFillDeep
    /// Neutral trend chart background.
    static let chartBackgroundFill = Colors.dataBackground
    /// Opacity used for mastery-distribution bar fill.
    static let chartMasteryBarOpacity: CGFloat = 0.7
}

// MARK: - Convenience ViewModifiers

extension View {
    /// Applies the standard card styling: padding + surface fill + small radius.
    /// Replaces ~18 repeated `.padding() .background(.quaternary.opacity(…)) .clipShape(RoundedRectangle(cornerRadius: 8))` blocks.
    func studyCard(fill: Color = StudyDesign.Colors.surfaceFill,
                   radius: CGFloat = StudyDesign.Radius.small) -> some View {
        self
            .padding(StudyDesign.Spacing.normal)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    /// Applies a subtle hairline stroke around a card or row.
    func studyCardStroke(color: Color = StudyDesign.Colors.accentHairline,
                         radius: CGFloat = StudyDesign.Radius.small,
                         lineWidth: CGFloat = 1) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(color, lineWidth: lineWidth)
        )
    }
}

// MARK: - Motion ViewModifier (private)

private struct _MotionViewModifier: ViewModifier, Equatable {
    let token: StudyDesign.MotionToken
    let value: AnyHashable

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.token == rhs.token && lhs.value == rhs.value
    }

    func body(content: Content) -> some View {
        content
            .animation(StudyDesign.Motion.animation(token), value: value)
    }
}

extension View {
    /// Applies a design-system animation to the attached view, automatically
    /// respecting Reduce Motion. Usage:
    /// ```swift
    /// .studyMotion(.spring, value: myValue)
    /// ```
    func studyMotion(_ token: StudyDesign.MotionToken, value: some Hashable) -> some View {
        modifier(StudyDesign.Motion.modifier(token, value: value))
    }
}
