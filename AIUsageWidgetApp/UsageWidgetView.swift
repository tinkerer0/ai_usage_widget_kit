import SwiftUI

struct UsageWidgetView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(spacing: 12) {
            ForEach(store.snapshot.rows) { row in
                UsageRowView(row: row, theme: theme)
            }
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: true, vertical: true)
        .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.borderColor, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            RefreshButton(theme: theme)
                .padding(.top, 6)
                .padding(.trailing, 8)
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private var theme: WidgetThemeMode { .dark }
}

struct RefreshButton: View {
    let theme: WidgetThemeMode

    @EnvironmentObject private var store: UsageStore
    @State private var isHovering = false

    var body: some View {
        Button {
            store.forceRefreshNow()
        } label: {
            Group {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.secondaryTextColor)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isRefreshing)
        .help("Refresh now")
        .accessibilityLabel("Refresh usage")
    }
}

struct UsageRowView: View {
    let row: UsageRow
    let theme: WidgetThemeMode

    var body: some View {
        HStack(spacing: 14) {
            RowProviderIcon(row: row, size: 38, theme: theme)
                .frame(width: 46, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(displayMetrics, id: \.label) { metric in
                    UsageMetricLine(metric: metric, color: accentColor, theme: theme)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .center)
    }

    private var rowHeight: CGFloat {
        switch displayMetrics.count {
        case 0, 1:
            return 56
        case 2:
            return 80
        default:
            return 112
        }
    }

    private var accentColor: Color {
        theme.accentColor(provider: row.provider, freshness: row.freshness, progress: row.progress)
    }

    private var displayMetrics: [UsageWindowMetric] {
        let metrics = [row.fiveHour, row.weekly, row.extra].compactMap { $0 }
        if !metrics.isEmpty { return metrics }
        return [
            UsageWindowMetric(
                label: "Week",
                valueText: row.valueText,
                progress: row.progress,
                detail: row.detail
            )
        ]
    }
}

struct UsageMetricLine: View {
    let metric: UsageWindowMetric
    let color: Color
    let theme: WidgetThemeMode

    var body: some View {
        HStack(spacing: 8) {
            Text(metric.label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(theme.secondaryTextColor)
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                MiniProgressLine(progress: metric.progress, color: color, trackColor: theme.trackColor)
                    .frame(height: 8)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let resetAt = metric.resetAt,
                       let remaining = Formatters.remainingString(until: resetAt, from: context.date) {
                        Text(remaining)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.resetTextColor)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(metric.valueText)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.primaryTextColor)
                .lineLimit(1)
                .frame(width: 42, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct RowProviderIcon: View {
    let row: UsageRow
    let size: CGFloat
    let theme: WidgetThemeMode

    var body: some View {
        Group {
            if let iconName = appIconName {
                Image(iconName)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .saturation(theme.isMonochrome ? 0 : 1)
                    .grayscale(theme.isMonochrome ? 1 : 0)
                    .contrast(theme.isMonochrome ? 1.18 : 1)
            } else {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(theme.isLight ? 0.10 : 0.18))

                    Circle()
                        .stroke(accentColor.opacity(0.78), lineWidth: 1)

                    AppFallbackProviderSymbol(provider: row.provider, color: accentColor, size: size * 0.58)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(row.title)
    }

    private var accentColor: Color {
        theme.accentColor(provider: row.provider, freshness: row.freshness, progress: row.progress)
    }

    private var appIconName: String? {
        switch row.provider {
        case .codex:
            return "CodexWidgetIcon"
        case .claude:
            return "ClaudeWidgetIcon"
        case .grok:
            return "GrokWidgetIcon"
        case .cursor:
            return "CursorWidgetIcon"
        case .openAIAPI, .anthropicAPI:
            return nil
        }
    }
}

struct AppFallbackProviderSymbol: View {
    let provider: UsageProvider
    let color: Color
    let size: CGFloat

    var body: some View {
        switch provider {
        case .openAIAPI:
            Image(systemName: "dollarsign")
                .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        case .anthropicAPI:
            Image(systemName: "creditcard.fill")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(color)
        case .grok:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(color)
        case .codex, .claude, .grok, .cursor:
            EmptyView()
        }
    }
}

struct MiniProgressLine: View {
    let progress: Double?
    let color: Color
    let trackColor: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                Capsule()
                    .fill(color)
                    .frame(width: fillWidth(in: proxy.size.width))
            }
        }
    }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        let fallback = min(width, 34)
        guard let progress else { return fallback }
        return max(5, min(width, width * CGFloat(progress)))
    }
}
