import Darwin
import Foundation

enum BackgroundAgentInstaller {
    private static let label = "local.aiusage.widgetkit.agent"

    static func installOrRefresh() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let fileManager = FileManager.default
        let launchAgents = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgents.appendingPathComponent("\(label).plist")

        do {
            try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/AIUsageWidget", isDirectory: true),
                withIntermediateDirectories: true
            )
            let payload = plist(executablePath: executablePath)
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            let unchanged = (try? Data(contentsOf: plistURL)) == data
            if !unchanged {
                try data.write(to: plistURL, options: .atomic)
            }
            loadIntoLaunchd(plistURL: plistURL, restart: !unchanged)
        } catch {
            return
        }
    }

    private static func loadIntoLaunchd(plistURL: URL, restart: Bool) {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let service = "\(domain)/\(label)"
        if restart {
            runLaunchctl(["bootout", service])
        }
        runLaunchctl(["bootstrap", domain, plistURL.path])
        runLaunchctl(["enable", service])
        if restart {
            runLaunchctl(["kickstart", "-k", service])
        }
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func plist(executablePath: String) -> [String: Any] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageWidget", isDirectory: true)
        return [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": support.appendingPathComponent("agent.out.log").path,
            "StandardErrorPath": support.appendingPathComponent("agent.err.log").path
        ]
    }
}
