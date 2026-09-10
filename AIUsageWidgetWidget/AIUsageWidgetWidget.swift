import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private let widgetKind = "AIUsageWidgetLive"

/// Interactive-widget refresh: the sandboxed extension can't reach the host
/// app directly, so it stamps refresh.request in its own container's
/// Application Support — the host app watches that file and rebakes the
/// snapshot (which triggers a timeline reload).
struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh AI Usage"
    static var description = IntentDescription("Ask the AI Usage Widget app to refresh usage data.")

    func perform() async throws -> some IntentResult {
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = support.appendingPathComponent("AIUsageWidget", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? stamp.data(using: .utf8)?.write(to: dir.appendingPathComponent("refresh.request"), options: .atomic)
            markSnapshotRefreshing(in: dir.appendingPathComponent("snapshot.json"))
        }
        return .result()
    }

    private func markSnapshotRefreshing(in url: URL) {
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        json["isRefreshing"] = true
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? updated.write(to: url, options: .atomic)
    }
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        completion(UsageWidgetEntry(date: Date(), snapshot: WidgetSnapshotReader.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let snapshot = WidgetSnapshotReader.load()
        let entry = UsageWidgetEntry(date: snapshot.generatedAt, snapshot: snapshot)
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct AIUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry

    var body: some View {
        Group {
            if isLarge {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
                        WidgetUsageRow(row: row, compact: false, palette: palette)
                        if index < displayRows.count - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
                        WidgetUsageRow(row: row, compact: true, palette: palette)
                        if index < displayRows.count - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, isLarge ? 16 : 10)
        .padding(.vertical, isLarge ? 14 : 6)
        .overlay(alignment: .bottomTrailing) {
            Group {
                if entry.snapshot.refreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.secondaryTextColor)
                        .padding(isLarge ? 6 : 4)
                } else {
                    Button(intent: RefreshUsageIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: isLarge ? 11 : 9, weight: .bold))
                            .foregroundStyle(palette.secondaryTextColor.opacity(0.85))
                            .padding(isLarge ? 6 : 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, isLarge ? 10 : 8)
            .padding(.bottom, isLarge ? 10 : 8)
            .accessibilityLabel("Refresh usage")
        }
        .containerBackground(for: .widget) {
            palette.backgroundColor
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private var isLarge: Bool { family == .systemLarge }

    private var palette: WidgetThemePalette {
        WidgetThemePalette(mode: entry.snapshot.themeMode)
    }

    private var displayRows: [WidgetUsageRowModel] {
        let liveRows = entry.snapshot.rows
            .filter { ["Codex", "Claude", "Grok", "Cursor"].contains($0.title) }
            .sorted { $0.sortOrder < $1.sortOrder }
        return Array(liveRows.prefix(4))
    }
}

struct WidgetUsageRow: View {
    let row: WidgetUsageRowModel
    let compact: Bool
    let palette: WidgetThemePalette

    var body: some View {
        HStack(spacing: compact ? 8 : 14) {
            ProviderIcon(row: row, size: compact ? 26 : 36, palette: palette)
                .frame(width: compact ? 34 : 44, alignment: .center)

            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                ForEach(row.metrics(compact: compact)) { metric in
                    WidgetUsageMetricLine(metric: metric, color: palette.accentColor(for: row), compact: compact, palette: palette)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .center)
        .layoutPriority(1)
    }

    private var rowHeight: CGFloat {
        let count = max(1, row.metrics(compact: compact).count)
        if compact {
            return CGFloat(14 + count * 18)
        }
        return CGFloat(18 + count * 26)
    }
}

struct WidgetUsageMetricLine: View {
    let metric: WidgetUsageMetricModel
    let color: Color
    let compact: Bool
    let palette: WidgetThemePalette

    var body: some View {
        HStack(spacing: compact ? 4 : 7) {
            Text(metric.label)
                .font(.system(size: compact ? 7 : 9, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryTextColor)
                .lineLimit(1)
                .frame(width: compact ? 34 : 46, alignment: .leading)

            VStack(alignment: .leading, spacing: compact ? 0 : 1) {
                ProgressLine(progress: metric.progress, color: color, trackColor: palette.trackColor)
                    .frame(height: compact ? 5 : 7)
                if let remaining = metric.remainingText {
                    Text(remaining)
                        .font(.system(size: compact ? 6 : 7, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.resetTextColor)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(metric.valueText)
                .font(.system(size: compact ? 10 : 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: compact ? 34 : 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct ProviderIcon: View {
    let row: WidgetUsageRowModel
    let size: CGFloat
    let palette: WidgetThemePalette

    var body: some View {
        Group {
            if let iconName = appIconName {
                Image(iconName)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .saturation(palette.isMonochrome ? 0 : 1)
                    .grayscale(palette.isMonochrome ? 1 : 0)
                    .contrast(palette.isMonochrome ? 1.18 : 1)
            } else {
                ZStack {
                    Circle()
                        .fill(palette.accentColor(for: row).opacity(palette.isLight ? 0.10 : 0.18))

                    Circle()
                        .stroke(palette.accentColor(for: row).opacity(0.78), lineWidth: 1)

                    FallbackProviderSymbol(kind: row.title, color: palette.accentColor(for: row), size: size * 0.58)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(row.title)
    }

    private var appIconName: String? {
        switch row.title {
        case "Codex":
            return "CodexWidgetIcon"
        case "Claude":
            return "ClaudeWidgetIcon"
        case "Grok":
            return "GrokWidgetIcon"
        case "Cursor":
            return "CursorWidgetIcon"
        default:
            return nil
        }
    }
}

struct FallbackProviderSymbol: View {
    let kind: String
    let color: Color
    let size: CGFloat

    var body: some View {
        switch kind {
        case "OpenAI API":
            Image(systemName: "dollarsign")
                .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        case "Anthropic API":
            Image(systemName: "creditcard.fill")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(color)
        case "Grok":
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(color)
        case "Cursor":
            Image(systemName: "cursorarrow")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(color)
        default:
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

struct ProgressLine: View {
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
        let fallback = min(width, 22)
        guard let progress else { return fallback }
        return max(4, min(width, width * CGFloat(progress)))
    }
}

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: UsageTimelineProvider()) { entry in
            AIUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("Codex, Claude, Grok, Cursor usage. Prefer Large size.")
        .supportedFamilies([.systemMedium, .systemLarge])
        // Without this, Medium content area is shorter than 3 compact rows and Grok is clipped.
        .contentMarginsDisabled()
    }
}

@main
struct AIUsageWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        AIUsageWidget()
    }
}

private enum WidgetSnapshotReader {
    static func load() -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshots = readableSnapshotURLs.compactMap { url -> WidgetSnapshot? in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return nil }
            return snapshot
        }

        return snapshots.max { $0.generatedAt < $1.generatedAt } ?? .placeholder
    }

    private static var readableSnapshotURLs: [URL] {
        [
            applicationSupportURL(),
            widgetExtensionContainerURL(id: "local.aiusage.widgetkit.widget"),
            userApplicationSupportURL()
        ]
    }

    private static func applicationSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AIUsageWidget", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    private static func widgetExtensionContainerURL(id: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(id)/Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent("AIUsageWidget", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    private static func userApplicationSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AIUsageWidget", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }
}

struct WidgetSnapshot: Decodable {
    let generatedAt: Date
    let theme: String?
    let isRefreshing: Bool?
    let rows: [WidgetUsageRowModel]

    static let placeholder = WidgetSnapshot(
        generatedAt: Date(),
        theme: WidgetThemeMode.defaultMode.rawValue,
        isRefreshing: false,
        rows: [
            WidgetUsageRowModel(title: "Codex", detail: "Waiting for data", valueText: "--", progress: nil, fiveHour: .placeholder("5h"), weekly: .placeholder("Week"), extra: nil, freshness: "Setup", sortOrder: 0),
            WidgetUsageRowModel(title: "Claude", detail: "Waiting for data", valueText: "--", progress: nil, fiveHour: .placeholder("5h"), weekly: .placeholder("Week"), extra: .placeholder("Fable"), freshness: "Setup", sortOrder: 1),
            WidgetUsageRowModel(title: "Grok", detail: "Waiting for data", valueText: "--", progress: nil, fiveHour: .placeholder("5h"), weekly: .placeholder("Week"), extra: nil, freshness: "Setup", sortOrder: 2)
        ]
    )

    var themeMode: WidgetThemeMode { .dark }

    var refreshing: Bool { isRefreshing ?? false }
}

struct WidgetUsageMetricModel: Decodable, Identifiable {
    let label: String
    let valueText: String
    let progress: Double?
    let detail: String
    let resetAt: Date?

    var id: String { label }

    var remainingText: String? {
        resetAt.flatMap { Formatters.remainingString(until: $0) }
    }

    static func placeholder(_ label: String) -> WidgetUsageMetricModel {
        WidgetUsageMetricModel(label: label, valueText: "--", progress: nil, detail: "Waiting for data", resetAt: nil)
    }
}

struct WidgetUsageRowModel: Decodable, Identifiable {
    let title: String
    let detail: String
    let valueText: String
    let progress: Double?
    let fiveHour: WidgetUsageMetricModel?
    let weekly: WidgetUsageMetricModel?
    let extra: WidgetUsageMetricModel?
    let freshness: String
    let sortOrder: Int

    var id: String { title }

    var displayMetrics: [WidgetUsageMetricModel] {
        metrics(compact: false)
    }

    func metrics(compact: Bool) -> [WidgetUsageMetricModel] {
        let all = [fiveHour, weekly, extra].compactMap { $0 }
        if compact, extra == nil {
            if let weekly { return [weekly] }
            if let fiveHour { return [fiveHour] }
        }
        if !all.isEmpty { return all }
        return [
            WidgetUsageMetricModel(
                label: "Week",
                valueText: valueText,
                progress: progress,
                detail: detail,
                resetAt: nil
            )
        ]
    }

    var accentColor: Color {
        if title == "Codex" {
            return Color(red: 0.22, green: 0.56, blue: 1.0)
        }
        if title == "Claude" {
            return Color(red: 1.0, green: 0.55, blue: 0.20)
        }
        if title == "Grok" {
            // Soft purple (#967fc9)
            return Color(red: 0.588, green: 0.498, blue: 0.788)
        }
        if title == "Cursor" {
            return Color(red: 0.92, green: 0.92, blue: 0.90)
        }
        if freshness == "Setup" {
            return .white.opacity(0.42)
        }
        if title == "OpenAI API" {
            return Color(red: 0.26, green: 0.78, blue: 0.58)
        }
        if title == "Anthropic API" {
            return Color(red: 0.72, green: 0.62, blue: 1.0)
        }
        if freshness == "Official" {
            return Color(red: 0.38, green: 0.68, blue: 1.0)
        }
        if freshness == "Delayed" {
            return Color(red: 0.96, green: 0.66, blue: 0.28)
        }

        let p = progress ?? 0
        if p >= 0.85 {
            return Color(red: 1.0, green: 0.38, blue: 0.34)
        }
        if p >= 0.60 {
            return Color(red: 0.98, green: 0.73, blue: 0.30)
        }
        return Color(red: 0.34, green: 0.84, blue: 0.56)
    }

}

private enum Formatters {
    static func clockString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func remainingString(until date: Date, from now: Date = Date()) -> String? {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "soon" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 24 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }
}

enum WidgetThemeMode: String {
    case dark
    case light
    case monoDark
    case monoLight

    static let defaultMode: WidgetThemeMode = .dark

    var isLight: Bool {
        self == .light || self == .monoLight
    }

    var isMonochrome: Bool {
        self == .monoDark || self == .monoLight
    }
}

struct WidgetThemePalette {
    let mode: WidgetThemeMode

    var isLight: Bool { mode.isLight }
    var isMonochrome: Bool { mode.isMonochrome }

    var backgroundColor: Color {
        switch mode {
        case .dark:
            return Color(red: 0.08, green: 0.09, blue: 0.09)
        case .light:
            return Color(red: 0.96, green: 0.96, blue: 0.94)
        case .monoDark:
            return Color(red: 0.03, green: 0.03, blue: 0.03)
        case .monoLight:
            return Color(red: 0.98, green: 0.98, blue: 0.97)
        }
    }

    var primaryTextColor: Color {
        isLight ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
    }

    var secondaryTextColor: Color {
        isLight ? Color.black.opacity(0.56) : Color.white.opacity(0.66)
    }

    var resetTextColor: Color {
        isLight ? Color.black.opacity(0.46) : Color.white.opacity(0.45)
    }

    var trackColor: Color {
        isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.13)
    }

    func accentColor(for row: WidgetUsageRowModel) -> Color {
        if isMonochrome {
            return isLight ? Color.black.opacity(0.72) : Color.white.opacity(0.78)
        }
        return row.accentColor
    }
}
