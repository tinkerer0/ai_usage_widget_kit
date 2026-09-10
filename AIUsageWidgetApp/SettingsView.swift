import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(WidgetThemeMode.storageKey) private var themeRawValue = WidgetThemeMode.defaultMode.rawValue

    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Live Usage Sources")
                .font(.system(size: 18, weight: .semibold))

            Text("Reads Claude/Codex/Grok from their usage APIs (no extra agent processes). Cursor uses an unofficial dashboard API when a token is available.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Theme is dark only.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Button(store.isRefreshing ? "Refreshing…" : "Refresh Now") {
                    store.forceRefreshNow()
                    status = "Refresh requested"
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isRefreshing)
                Spacer()
            }

            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Live sources")
                    .font(.system(size: 13, weight: .semibold))
                Text("Codex: chatgpt.com/backend-api/wham/usage")
                Text("Claude: api.anthropic.com/api/oauth/usage")
                Text("Grok: cli-chat-proxy billing (same SuperGrok weekly pool as Build)")
                Text("Cursor: unofficial DashboardService/GetCurrentPeriodUsage")
                Text("Poll: 15 minutes. Refresh does not spawn claude/codex.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if themeRawValue != WidgetThemeMode.dark.rawValue {
                themeRawValue = WidgetThemeMode.dark.rawValue
                store.refreshWidgetAppearance()
            }
        }
    }
}
