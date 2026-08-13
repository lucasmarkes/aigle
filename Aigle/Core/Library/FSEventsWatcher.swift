import CoreServices
import Foundation

/// Thin wrapper around FSEvents for recursive live updates of the library folder
/// and every connected folder.
public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "cool.aigle.fsevents")

    public init(paths: [URL], latency: TimeInterval = 0.6, handler: @escaping @Sendable ([String]) -> Void) {
        guard !paths.isEmpty else { return }

        let box = Unmanaged.passRetained(CallbackBox(handler: handler)).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: box,
            retain: nil,
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<CallbackBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            _ = count
            box.handler(paths)
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private final class CallbackBox {
        let handler: @Sendable ([String]) -> Void
        init(handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
    }
}
