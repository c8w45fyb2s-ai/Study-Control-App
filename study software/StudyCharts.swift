import SwiftUI

// MARK: - StudyTrendCharts (upgraded)

/// Weekly activity bars + mastery distribution + stats summary.
/// Designed to feel like Apple Health — gradient fills, rounded bars,
/// semantic mastery gradients, and a `ListCard` container.
///
/// All bar widths are derived from `GeometryReader` so the charts
/// adapt to small screens, split-view, and Dynamic Type.
struct StudyTrendCharts: View {
    var activityRecords: [DailyActivityRecord]
    var knowledgePoints: [KnowledgePoint]
    var reviewTasks: [ReviewTask]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedWeeklyLabel: String?
    @State private var selectedMasteryLabel: String?
    @State private var trendLineProgress: CGFloat = 0

    /// Spacing between bars, shared so geometry calculations stay consistent.
    private let barSpacing: CGFloat = StudyDesign.Spacing.tight

    // MARK: - Data helpers --------------------------------------------------

    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f
    }()

    private var weeklyActivity: [(label: String, count: Int)] {
        var result: [(label: String, count: Int)] = []
        for daysBack in stride(from: 6, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: Date()) else { continue }
            let key = DailyActivityRecord.dateString(from: date)
            let record = activityRecords.first { $0.dateString == key }
            result.append((dateFormatter.string(from: date), record?.completedTaskCount ?? 0))
        }
        return result
    }

    private var weeklyMaxCount: Int {
        max(weeklyActivity.map(\.count).max() ?? 1, 1)
    }

    private var masteryDistribution: [(label: String, count: Int)] {
        let levels: [(String, Range<Double>)] = [
            ("薄弱 (<25%)",   0..<0.25),
            ("学习中 (25-50%)", 0.25..<0.5),
            ("熟练 (50-80%)",  0.5..<0.8),
            ("已掌握 (≥80%)",   0.8..<1.01)
        ]
        return levels.map { level in
            (level.0, knowledgePoints.filter { level.1.contains($0.mastery) }.count)
        }
    }

    private var masteryMaxCount: CGFloat {
        CGFloat(masteryDistribution.map(\.count).max() ?? 1)
    }

    private var weeklyCompletedCount: Int {
        weeklyActivity.reduce(0) { $0 + $1.count }
    }

    private var weeklyActiveDays: Int {
        weeklyActivity.filter { $0.count > 0 }.count
    }

    private var reviewedTaskCount: Int {
        reviewTasks.filter { $0.lastQuality != nil }.count
    }

    private var reviewRateText: String {
        guard !reviewTasks.isEmpty else { return "—" }
        return "\(Int(Double(reviewedTaskCount) / Double(reviewTasks.count) * 100))%"
    }

    private var averageMasteryText: String {
        guard !knowledgePoints.isEmpty else { return "—" }
        let average = knowledgePoints.map(\.mastery).reduce(0, +) / Double(knowledgePoints.count)
        return "\(Int((average * 100).rounded()))%"
    }

    /// Semantic gradients for each mastery tier.
    private let masteryGradients: [LinearGradient] = [
        LinearGradient(colors: [StudyDesign.Colors.danger, StudyDesign.Colors.warning], startPoint: .leading, endPoint: .trailing),
        LinearGradient(colors: [StudyDesign.Colors.warning, StudyDesign.Colors.warning.opacity(0.62)], startPoint: .leading, endPoint: .trailing),
        LinearGradient(
            colors: [StudyDesign.Colors.info.opacity(0.72), StudyDesign.Colors.secondary.opacity(0.54)],
            startPoint: .leading, endPoint: .trailing
        ),
        LinearGradient(colors: [StudyDesign.Colors.success.opacity(0.78), StudyDesign.Colors.success], startPoint: .leading, endPoint: .trailing)
    ]

    // MARK: - Bar gradient ---------------------------------------------------

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [
                StudyDesign.Colors.success.opacity(0.94),
                StudyDesign.Colors.warning.opacity(0.70)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Body -----------------------------------------------------------

    var body: some View {
        ListCard(tint: StudyDesign.Colors.info) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                chartDashboardHeader
                chartDivider
                weeklyChartSection
                chartDivider
                masteryChartSection
                chartDivider
                statsSummary
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("学习趋势图表：最近七天活动、掌握度分布、统计汇总")
    }

    private var chartDashboardHeader: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.info)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                            .fill(StudyDesign.Gradients.dataSurface)
                    )
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(StudyDesign.Colors.info)
                            .frame(width: 3)
                            .padding(.vertical, StudyDesign.Spacing.compact)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                            .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("学习趋势")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("最近 7 天复习节奏、知识掌握度和任务完成情况。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.normal)

                ChartStatusPill(
                    title: "本周完成",
                    value: "\(weeklyCompletedCount)",
                    tint: StudyDesign.Colors.success
                )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                ChartSummaryTile(title: "活跃天数", value: "\(weeklyActiveDays)/7", icon: "calendar", tint: StudyDesign.Colors.warning)
                ChartSummaryTile(title: "平均掌握", value: averageMasteryText, icon: "gauge.with.dots.needle.67percent", tint: StudyDesign.Colors.success)
                ChartSummaryTile(title: "复习率", value: reviewRateText, icon: "checkmark.seal.fill", tint: StudyDesign.Colors.info)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Gradients.featureSurface)
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Gradients.semanticWash(StudyDesign.Colors.info).opacity(0.18))
                Rectangle()
                    .fill(StudyDesign.Colors.info)
                    .frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.62), lineWidth: 1)
        )
    }

    private var chartDivider: some View {
        Rectangle()
            .fill(StudyDesign.Colors.accentHairline.opacity(0.52))
            .frame(height: 1)
    }

    // MARK: - Weekly chart --------------------------------------------------

    @ViewBuilder
    private var weeklyChartSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            ChartSectionHeader(
                title: "最近 7 天打卡",
                subtitle: weeklyActiveDays == 0 ? "本周还没有完成记录" : "已有 \(weeklyActiveDays) 天产生复习记录",
                icon: "chart.bar.xaxis",
                tint: StudyDesign.Colors.warning,
                value: "\(weeklyCompletedCount)"
            )

            if weeklyActivity.isEmpty {
                weeklyEmptyView
            } else {
                GeometryReader { geo in
                    weeklyHealthChart(in: geo.size)
                }
                .frame(height: 180)
                .onAppear {
                    animateTrendLine()
                }
                .onChange(of: weeklyActivity.map(\.count)) { _, _ in
                    animateTrendLine()
                }
            }
        }
    }

    private func weeklyHealthChart(in size: CGSize) -> some View {
        let plotHeight = max(size.height - 52, 1)

        return VStack(spacing: StudyDesign.Spacing.compact) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.dataBackground,
                                StudyDesign.Colors.elevatedBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle()
                                    .fill(StudyDesign.Colors.accentHairline.opacity(0.22))
                                    .frame(height: 1)
                            }
                        }
                        .padding(StudyDesign.Spacing.tight)
                    }

                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(Array(weeklyActivity.enumerated()), id: \.element.label) { index, day in
                        WeeklyActivityColumn(
                            day: day,
                            index: index,
                            maxCount: weeklyMaxCount,
                            gradient: barGradient,
                            isSelected: selectedWeeklyLabel == day.label
                        ) { label in
                            selectedWeeklyLabel = selectedWeeklyLabel == label ? nil : label
                        } hover: { label in
                            selectedWeeklyLabel = label
                        }
                    }
                }
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.top, StudyDesign.Spacing.tight)
                .padding(.bottom, StudyDesign.Spacing.compact)

                WeeklyTrendLine(
                    counts: weeklyActivity.map(\.count),
                    maxCount: weeklyMaxCount,
                    progress: trendLineProgress
                )
                .stroke(
                    StudyDesign.Colors.success.opacity(0.70),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, StudyDesign.Spacing.tight)
                .allowsHitTesting(false)

                if let tooltip = selectedWeeklyTooltip(in: size.width) {
                    ChartTooltip(title: tooltip.title, value: tooltip.value, accent: tooltip.accent)
                        .position(x: tooltip.x, y: 20)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: plotHeight)
            .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast), value: selectedWeeklyLabel)

            HStack(spacing: barSpacing) {
                ForEach(weeklyActivity, id: \.label) { day in
                    Button {
                        selectedWeeklyLabel = selectedWeeklyLabel == day.label ? nil : day.label
                    } label: {
                        WeeklyCheckInDot(
                            label: day.label,
                            count: day.count,
                            isCheckedIn: day.count > 0,
                            isSelected: selectedWeeklyLabel == day.label
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .iOSTouchTarget()
                    .accessibilityLabel(day.count > 0 ? "\(day.label)，已打卡，完成 \(day.count) 项复习" : "\(day.label)，未打卡")
                    .accessibilityHint("查看这一天的复习记录")
                    .help(day.count > 0 ? "\(day.label)：完成 \(day.count) 项复习" : "\(day.label)：未打卡")
                }
            }
            .padding(.top, 1)

            HStack(spacing: barSpacing) {
                ForEach(weeklyActivity, id: \.label) { day in
                    Text(day.label)
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func selectedWeeklyTooltip(in width: CGFloat) -> (title: String, value: String, x: CGFloat, accent: Color)? {
        guard
            let selectedWeeklyLabel,
            let index = weeklyActivity.firstIndex(where: { $0.label == selectedWeeklyLabel })
        else { return nil }

        let day = weeklyActivity[index]
        let columnWidth = width / CGFloat(max(weeklyActivity.count, 1))
        let rawX = columnWidth * (CGFloat(index) + 0.5)
        let clampedX = min(max(rawX, 64), max(width - 64, 64))
        if day.count > 0 {
            return (day.label, "已打卡 · \(day.count) 项复习", clampedX, StudyDesign.Colors.warning)
        }
        return (day.label, "未打卡", clampedX, StudyDesign.Colors.labelTertiary)
    }

    private func animateTrendLine() {
        if reduceMotion {
            trendLineProgress = 1
            return
        }

        trendLineProgress = 0
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.heroReveal).delay(0.18)) {
            trendLineProgress = 1
        }
    }

    private var weeklyEmptyView: some View {
        VStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
            Text("暂无数据")
                .font(.subheadline)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, StudyDesign.Spacing.relaxed)
        .background(StudyDesign.Gradients.dataSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
    }

    // MARK: - Mastery chart -------------------------------------------------

    @ViewBuilder
    private var masteryChartSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            ChartSectionHeader(
                title: "掌握度分布",
                subtitle: knowledgePoints.isEmpty ? "确认分析草稿后会出现分布" : "\(knowledgePoints.count) 个知识点进入掌握度追踪",
                icon: "chart.pie.fill",
                tint: StudyDesign.Colors.success,
                value: "\(knowledgePoints.count)"
            )

            if masteryDistribution.allSatisfy({ $0.count == 0 }) {
                masteryEmptyView
            } else {
                GeometryReader { geo in
                    VStack(spacing: StudyDesign.Spacing.normal) {
                        ForEach(Array(zip(masteryDistribution.indices, zip(masteryDistribution, masteryGradients))), id: \.1.0.label) { index, pair in
                            let item = pair.0
                            let gradient = pair.1

                            MasteryDistributionRow(
                                item: item,
                                gradient: gradient,
                                maxCount: masteryMaxCount,
                                index: index,
                                isSelected: selectedMasteryLabel == item.label
                            ) { label in
                                selectedMasteryLabel = selectedMasteryLabel == label ? nil : label
                            } hover: { label in
                                selectedMasteryLabel = label
                            }
                        }
                    }
                }
                .frame(height: CGFloat(masteryDistribution.count) * 54)
            }
        }
    }

    private var masteryEmptyView: some View {
        VStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: "chart.pie")
                .font(.system(size: 28))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
            Text("暂无知识点")
                .font(.subheadline)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, StudyDesign.Spacing.relaxed)
        .background(StudyDesign.Gradients.dataSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
    }

    // MARK: - Stats summary -------------------------------------------------

    private var statsSummary: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            ChartSectionHeader(
                title: "复习队列快照",
                subtitle: "从任务完成情况判断当前节奏是否稳定",
                icon: "rectangle.stack.badge.play.fill",
                tint: StudyDesign.Colors.info,
                value: reviewRateText
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                StatItem(label: "总复习任务", value: "\(reviewTasks.count)", icon: "tray.full.fill", tint: StudyDesign.Colors.secondary)
                StatItem(label: "已复习", value: "\(reviewedTaskCount)", icon: "checkmark.circle.fill", tint: StudyDesign.Colors.success)
                StatItem(label: "复习率", value: reviewRateText, icon: "percent", tint: StudyDesign.Colors.info)
            }
        }
    }
}

// MARK: - Apple Health Style Chart Pieces

private struct ChartStatusPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
	        .background(Capsule().fill(StudyDesign.Colors.dataBackground))
	        .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
	        .accessibilityElement(children: .ignore)
	        .accessibilityLabel("\(title)：\(value)")
    }
}

private struct ChartSummaryTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(StudyDesign.Colors.dataBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.elevatedBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
	        .overlay(
	            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
	                .stroke(StudyDesign.Colors.accentHairline.opacity(0.54), lineWidth: 1)
	        )
	        .accessibilityElement(children: .ignore)
	        .accessibilityLabel("\(title)：\(value)")
    }
}

private struct ChartSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(StudyDesign.Colors.dataBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Text(value)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, StudyDesign.Spacing.micro)
                .background(Capsule().fill(StudyDesign.Colors.dataBackground))
                .overlay(Capsule().stroke(tint.opacity(0.16), lineWidth: 1))
        }
    }
}

private struct WeeklyActivityColumn: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    let day: (label: String, count: Int)
    let index: Int
    let maxCount: Int
    let gradient: LinearGradient
    let isSelected: Bool
    let select: (String) -> Void
    let hover: (String?) -> Void

    var body: some View {
        let base = Button {
            select(day.label)
        } label: {
            GeometryReader { geo in
                let ratio = maxCount > 0 ? CGFloat(day.count) / CGFloat(maxCount) : 0
                let height = day.count > 0 ? max(8, geo.size.height * ratio * progress) : 0

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(StudyDesign.chartEmptyBarFill.opacity(isSelected ? 0.86 : 0.58))
                        .frame(width: 16, height: geo.size.height)

                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(gradient)
                        .frame(width: 16, height: height)
                        .opacity(day.count > 0 ? 1 : 0)
                        .shadow(
                            color: StudyDesign.Colors.success.opacity(isSelected ? 0.18 : 0.07),
                            radius: isSelected ? 8 : 3,
                            y: isSelected ? 2 : 1
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .scaleEffect(isSelected ? 1.035 : 1)
        .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast), value: isSelected)
        .accessibilityLabel("\(day.label)，完成 \(day.count) 项复习")
        .accessibilityHint("查看这一天的复习记录")
        .help("\(day.label)：完成 \(day.count) 项复习")
        .onAppear {
            animateIn()
        }
        .onChange(of: day.count) { _, _ in
            animateIn()
        }

#if os(macOS)
        base.onHover { isHovering in
            hover(isHovering ? day.label : nil)
        }
#else
        base
#endif
    }

    private func animateIn() {
        if reduceMotion {
            progress = 1
            return
        }

        progress = 0
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.heroReveal).delay(Double(index) * 0.055)) {
            progress = 1
        }
    }
}

private struct WeeklyCheckInDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let label: String
    let count: Int
    let isCheckedIn: Bool
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(dotFill)
                .frame(width: dotSize, height: dotSize)
                .shadow(
                    color: isCheckedIn ? StudyDesign.Colors.warning.opacity(isSelected ? 0.36 : 0.18) : .clear,
                    radius: isSelected ? 7 : 3,
                    y: 1
                )

            if isCheckedIn {
                Image(systemName: "flame.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .offset(y: -0.5)
            }
        }
        .overlay(
            Circle()
                .stroke(dotStroke, lineWidth: isSelected ? 2 : 1)
                .frame(width: dotSize + 5, height: dotSize + 5)
                .opacity(isSelected ? 1 : 0.65)
	        )
        .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast), value: isSelected)
        .accessibilityHidden(true)
    }

    private var dotSize: CGFloat {
        16
    }

    private var dotFill: some ShapeStyle {
        if isCheckedIn {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        StudyDesign.Colors.warning.opacity(0.72),
                        StudyDesign.Colors.info.opacity(0.42)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(StudyDesign.Colors.labelTertiary.opacity(0.28))
    }

    private var dotStroke: Color {
        isCheckedIn ? StudyDesign.Colors.warning.opacity(0.7) : StudyDesign.Colors.labelTertiary.opacity(0.32)
    }
}

private struct WeeklyTrendLine: Shape {
    let counts: [Int]
    let maxCount: Int
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard counts.count > 1 else { return Path() }

        let maxValue = max(maxCount, 1)
        let columnWidth = rect.width / CGFloat(counts.count)
        let usableHeight = max(rect.height - 10, 1)
        var path = Path()

        for index in counts.indices {
            let ratio = CGFloat(counts[index]) / CGFloat(maxValue)
            let point = CGPoint(
                x: columnWidth * (CGFloat(index) + 0.5),
                y: rect.maxY - 5 - (ratio * usableHeight)
            )

            if index == counts.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path.trimmedPath(from: 0, to: progress)
    }
}

private struct MasteryDistributionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    let item: (label: String, count: Int)
    let gradient: LinearGradient
    let maxCount: CGFloat
    let index: Int
    let isSelected: Bool
    let select: (String) -> Void
    let hover: (String?) -> Void

    private var ratio: CGFloat {
        guard maxCount > 0 else { return 0 }
        return CGFloat(item.count) / maxCount
    }

    private var masteryAccent: Color {
        switch index {
        case 0:
            return StudyDesign.Colors.danger
        case 1:
            return StudyDesign.Colors.warning
        case 2:
            return StudyDesign.Colors.info
        default:
            return StudyDesign.Colors.success
        }
    }

    var body: some View {
        let base = Button {
            select(item.label)
        } label: {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    Text("\(item.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StudyDesign.chartEmptyBarFill.opacity(isSelected ? 0.82 : 0.56))

                    Capsule()
                        .fill(gradient)
                        .scaleEffect(x: max(ratio * progress, item.count > 0 ? 0.035 : 0), y: 1, anchor: .leading)
                        .shadow(
                            color: masteryAccent.opacity(isSelected ? 0.14 : 0.05),
                            radius: isSelected ? 7 : 2,
                            y: 1
                        )
                }
                .frame(height: StudyDesign.Spacing.roomy)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if isSelected {
                let percent = Int((ratio * 100).rounded())
                ChartTooltip(title: item.label, value: "\(item.count) 个 · \(percent)%", accent: masteryAccent)
                    .offset(y: -34)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .onAppear {
            animateIn()
        }
        .onChange(of: item.count) { _, _ in
            animateIn()
        }
        .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast), value: isSelected)
        .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring), value: item.count)
        .accessibilityLabel("\(item.label)，\(item.count) 个知识点")
        .accessibilityHint("查看这个掌握度层级")
        .help("\(item.label)：\(item.count) 个知识点")

#if os(macOS)
        base.onHover { isHovering in
            hover(isHovering ? item.label : nil)
        }
#else
        base
#endif
    }

    private func animateIn() {
        if reduceMotion {
            progress = 1
            return
        }

        progress = 0
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring).delay(Double(index) * 0.065)) {
            progress = 1
        }
    }
}

private struct ChartTooltip: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .allowsHitTesting(false)
    }
}

// MARK: - StatItem

struct StatItem: View {
    var label: String
    var value: String
    var icon: String = "number"
    var tint: Color = StudyDesign.Colors.info

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(StudyDesign.Colors.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.56), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)：\(value)")
    }
}
