import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let store: UsageStore
    private let panelController: FloatingPanelController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var settingsWindow: NSWindow?

    init(store: UsageStore, panelController: FloatingPanelController) {
        self.store = store
        self.panelController = panelController

        if let button = statusItem.button {
            button.title = "AI"
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func refresh() {
        store.forceRefreshNow()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(store)
                .frame(width: 460)
                .padding(20)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AI Usage Settings"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
