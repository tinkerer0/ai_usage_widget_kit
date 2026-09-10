import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private var cancellable: AnyCancellable?

    init(store: UsageStore) {
        let content = AnyView(UsageWidgetView().environmentObject(store))
        hosting = NSHostingView(rootView: content)

        panel = NSPanel(
            contentRect: NSRect(x: 120, y: 720, width: 340, height: 310),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI Usage"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        applyDesktopWidgetLevel()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        fitToContent()
        cancellable = store.$snapshot.sink { [weak self] _ in
            self?.fitToContent()
        }
        show()
    }

    private func fitToContent() {
        hosting.invalidateIntrinsicContentSize()
        var size = hosting.fittingSize
        size.width = max(340, size.width)
        size.height = max(220, size.height)
        hosting.frame.size = size
        panel.setContentSize(size)
    }

    private func applyDesktopWidgetLevel() {
        // Above wallpaper/icons, below every normal app window.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func show() {
        applyDesktopWidgetLevel()
        panel.orderFront(nil)
        applyDesktopWidgetLevel()
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }
}
