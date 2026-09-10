import CoreServices
import Foundation

final class FileEventMonitor {
    private let paths: [URL]
    private let callback: () -> Void
    private let debounce: TimeInterval
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(paths: [URL], debounce: TimeInterval = 2.0, callback: @escaping () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.callback = callback
    }

    func start() {
        stop()
        let existingPaths = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileEventMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleCallback()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existingPaths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleCallback() {
        pending?.cancel()
        let item = DispatchWorkItem { [callback] in callback() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    deinit {
        stop()
    }
}
