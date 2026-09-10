import Foundation
import SwiftUI

enum UsageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case grok = "Grok"
    case cursor = "Cursor"
    case openAIAPI = "OpenAI API"
    case anthropicAPI = "Anthropic API"

    var id: String { rawValue }
}

enum Freshness: String, Sendable {
    case live = "Live"
    case recent = "Recent"
    case official = "Official"
    case delayed = "Delayed"
    case unavailable = "Setup"
}

enum UsageUnit: Sendable {
    case percent
    case tokens
    case usd
    case unknown
}

enum WidgetThemeMode: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case monoDark
    case monoLight

    static let storageKey = "AIUsageWidget.widgetTheme"
    static let defaultMode: WidgetThemeMode = .dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        case .monoDark:
            return "B/W Dark"
        case .monoLight:
            return "B/W Light"
        }
    }

    var isLight: Bool {
        self == .light || self == .monoLight
    }

    var isMonochrome: Bool {
        self == .monoDark || self == .monoLight
    }

    static var current: WidgetThemeMode { .dark }

    var backgroundColor: Color {
        switch self {
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

    var borderColor: Color {
        isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.10)
    }

    func accentColor(provider: UsageProvider, freshness: Freshness, progress: Double?) -> Color {
        if isMonochrome {
            return isLight ? Color.black.opacity(0.72) : Color.white.opacity(0.78)
        }

        switch provider {
        case .codex:
            return Color(red: 0.22, green: 0.56, blue: 1.0)
        case .claude:
            return Color(red: 1.0, green: 0.55, blue: 0.20)
        case .grok:
            // Soft purple (#967fc9)
            return Color(red: 0.588, green: 0.498, blue: 0.788)
        case .cursor:
            return Color(red: 0.92, green: 0.92, blue: 0.90)
        case .openAIAPI:
            return freshness == .unavailable ? Color.secondary : Color(red: 0.26, green: 0.78, blue: 0.58)
        case .anthropicAPI:
            return freshness == .unavailable ? Color.secondary : Color(red: 0.72, green: 0.62, blue: 1.0)
        }
    }
}

struct UsageWindowMetric: Equatable, Sendable {
    var label: String
    var valueText: String
    var progress: Double?
    var detail: String
    var resetAt: Date? = nil
}

struct UsageRow: Identifiable, Equatable, Sendable {
    let provider: UsageProvider
    var title: String
    var detail: String
    var valueText: String
    var progress: Double?
    var fiveHour: UsageWindowMetric?
    var weekly: UsageWindowMetric?
    var extra: UsageWindowMetric?
    var unit: UsageUnit
    var freshness: Freshness
    var updatedAt: Date?
    var resetAt: Date?
    var sortOrder: Int

    var id: UsageProvider { provider }

    init(
        provider: UsageProvider,
        title: String,
        detail: String,
        valueText: String,
        progress: Double?,
        fiveHour: UsageWindowMetric? = nil,
        weekly: UsageWindowMetric? = nil,
        extra: UsageWindowMetric? = nil,
        unit: UsageUnit,
        freshness: Freshness,
        updatedAt: Date?,
        resetAt: Date?,
        sortOrder: Int
    ) {
        self.provider = provider
        self.title = title
        self.detail = detail
        self.valueText = valueText
        self.progress = progress
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.extra = extra
        self.unit = unit
        self.freshness = freshness
        self.updatedAt = updatedAt
        self.resetAt = resetAt
        self.sortOrder = sortOrder
    }

    static func placeholder(_ provider: UsageProvider, order: Int) -> UsageRow {
        UsageRow(
            provider: provider,
            title: provider.rawValue,
            detail: "Waiting for data",
            valueText: "--",
            progress: nil,
            fiveHour: nil,
            weekly: nil,
            unit: .unknown,
            freshness: .unavailable,
            updatedAt: nil,
            resetAt: nil,
            sortOrder: order
        )
    }
}

struct UsageSnapshot: Equatable, Sendable {
    var rows: [UsageRow]
    var updatedAt: Date?
    var isRefreshing: Bool = false

    static let empty = UsageSnapshot(
        rows: [
            .placeholder(.codex, order: 0),
            .placeholder(.claude, order: 1),
            .placeholder(.grok, order: 2)
        ],
        updatedAt: nil,
        isRefreshing: false
    )
}

extension UsageRow {
    var accentColor: Color {
        switch provider {
        case .codex:
            return Color(red: 0.22, green: 0.56, blue: 1.0)
        case .claude:
            return Color(red: 1.0, green: 0.55, blue: 0.20)
        case .grok:
            return Color(red: 0.588, green: 0.498, blue: 0.788)
        case .cursor:
            return Color(red: 0.92, green: 0.92, blue: 0.90)
        case .openAIAPI:
            return freshness == .unavailable ? Color.secondary : Color(red: 0.26, green: 0.78, blue: 0.58)
        case .anthropicAPI:
            return freshness == .unavailable ? Color.secondary : Color(red: 0.72, green: 0.62, blue: 1.0)
        }
    }
}

enum Formatters {
    static func clockString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func resetString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000.0)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func percentMetric(label: String, usedPercent: Double, resetAt: Date?) -> UsageWindowMetric {
        let clampedPercent = max(0, min(usedPercent, 100))
        let detail = resetAt.map { "Reset \(resetString(from: $0))" } ?? label
        return UsageWindowMetric(
            label: label,
            valueText: "\(Int(clampedPercent.rounded()))%",
            progress: clampedPercent / 100,
            detail: detail,
            resetAt: resetAt
        )
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
