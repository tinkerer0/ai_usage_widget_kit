import Foundation

enum WidgetSnapshotStore {
    // Must match AIUsageWidgetWidget.swift `widgetKind`.
    static let widgetKind = "AIUsageWidgetLive"

    static func write(_ snapshot: UsageSnapshot) {
        let payload = WidgetSnapshotPayload(
            generatedAt: snapshot.updatedAt ?? Date(),
            theme: WidgetThemeMode.current.rawValue,
            isRefreshing: snapshot.isRefreshing,
            rows: snapshot.rows.map(WidgetSnapshotRow.init(row:))
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload) else { return }

        for url in writableSnapshotURLs {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                continue
            }
        }
    }

    static func read() -> UsageSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = applicationSupportURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(WidgetSnapshotPayload.self, from: data) else {
            return nil
        }
        let rows = payload.rows.compactMap(\.usageRow)
        guard !rows.isEmpty else { return nil }
        return UsageSnapshot(rows: rows, updatedAt: payload.generatedAt, isRefreshing: false)
    }

    private static var writableSnapshotURLs: [URL] {
        [
            applicationSupportURL(),
            widgetExtensionContainerURL(id: "local.aiusage.widgetkit.widget")
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

    /// The widget's sandboxed refresh button can only write inside its own
    /// container, so the request file lives next to the container snapshot.
    static var refreshRequestURL: URL {
        widgetExtensionContainerURL(id: "local.aiusage.widgetkit.widget")
            .deletingLastPathComponent()
            .appendingPathComponent("refresh.request")
    }
}

private struct WidgetSnapshotPayload: Codable {
    let generatedAt: Date
    let theme: String
    let isRefreshing: Bool
    let rows: [WidgetSnapshotRow]
}

private struct WidgetSnapshotRow: Codable {
    let title: String
    let detail: String
    let valueText: String
    let progress: Double?
    let fiveHour: WidgetSnapshotMetric?
    let weekly: WidgetSnapshotMetric?
    let extra: WidgetSnapshotMetric?
    let unit: String
    let freshness: String
    let sortOrder: Int

    init(row: UsageRow) {
        title = row.title
        detail = row.detail
        valueText = row.valueText
        progress = row.progress
        fiveHour = row.fiveHour.map(WidgetSnapshotMetric.init(metric:))
        weekly = row.weekly.map(WidgetSnapshotMetric.init(metric:))
        extra = row.extra.map(WidgetSnapshotMetric.init(metric:))
        unit = row.unit.snapshotValue
        freshness = row.freshness.rawValue
        sortOrder = row.sortOrder
    }

    var usageRow: UsageRow? {
        guard let provider = UsageProvider(rawValue: title),
              let freshness = Freshness(rawValue: freshness),
              freshness != .unavailable else { return nil }
        return UsageRow(
            provider: provider,
            title: title,
            detail: detail,
            valueText: valueText,
            progress: progress,
            fiveHour: fiveHour?.metric,
            weekly: weekly?.metric,
            extra: extra?.metric,
            unit: UsageUnit(snapshotValue: unit),
            freshness: freshness,
            updatedAt: nil,
            resetAt: extra?.resetAt ?? weekly?.resetAt ?? fiveHour?.resetAt,
            sortOrder: sortOrder
        )
    }
}

private struct WidgetSnapshotMetric: Codable {
    let label: String
    let valueText: String
    let progress: Double?
    let detail: String
    let resetAt: Date?

    init(metric: UsageWindowMetric) {
        label = metric.label
        valueText = metric.valueText
        progress = metric.progress
        detail = metric.detail
        resetAt = metric.resetAt
    }

    var metric: UsageWindowMetric {
        UsageWindowMetric(
            label: label,
            valueText: valueText,
            progress: progress,
            detail: detail,
            resetAt: resetAt
        )
    }
}

private extension UsageUnit {
    var snapshotValue: String {
        switch self {
        case .percent:
            return "percent"
        case .tokens:
            return "tokens"
        case .usd:
            return "usd"
        case .unknown:
            return "unknown"
        }
    }

    init(snapshotValue: String) {
        switch snapshotValue {
        case "percent":
            self = .percent
        case "tokens":
            self = .tokens
        case "usd":
            self = .usd
        default:
            self = .unknown
        }
    }
}
