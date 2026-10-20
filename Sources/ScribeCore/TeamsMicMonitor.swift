import Foundation

public struct AudioProcessInfo: Equatable, Sendable {
    public var bundleID: String
    public var isRunningInput: Bool

    public init(bundleID: String, isRunningInput: Bool) {
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
    }
}

/// Polls Core Audio and reports whether a Microsoft Teams process is using
/// the microphone. `onChange` fires on the main actor with the first
/// successful reading, then only when the value changes.
public final class TeamsMicMonitor: @unchecked Sendable {
    public static let bundlePrefix = "com.microsoft.teams2"

    /// True if any process matches the prefix and is running input.
    public static func teamsHoldsMic(_ processes: [AudioProcessInfo]) -> Bool {
        processes.contains { $0.bundleID.hasPrefix(bundlePrefix) && $0.isRunningInput }
    }

    /// Reads Core Audio; nil when the process list can't be read.
    public static func readCoreAudio() -> Bool? {
        guard let objects = CoreAudio.processObjects() else { return nil }
        return teamsHoldsMic(objects.map {
            AudioProcessInfo(bundleID: CoreAudio.bundleID(ofProcess: $0),
                             isRunningInput: CoreAudio.isRunningInput($0))
        })
    }

    private let interval: TimeInterval
    private let read: @Sendable () -> Bool?
    private let onChange: @MainActor @Sendable (Bool) -> Void
    private let queue = DispatchQueue(label: "scribe.teams-mic-monitor")
    private let lock = NSLock()
    private var lastReported: Bool?
    private var timer: DispatchSourceTimer?

    public init(interval: TimeInterval = 1,
                read: @escaping @Sendable () -> Bool? = TeamsMicMonitor.readCoreAudio,
                onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.interval = interval
        self.read = read
        self.onChange = onChange
    }

    /// Polls immediately, then every `interval`.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// One read; reports to `onChange` if it differs from the last report.
    func poll() {
        guard let value = read() else { return }
        let changed = lock.withLock { () -> Bool in
            guard lastReported != value else { return false }
            lastReported = value
            return true
        }
        guard changed else { return }
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(value) } }
    }

    deinit {
        stop()
    }
}
