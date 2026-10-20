import Foundation
import Testing
@testable import ScribeCore

/// Hands out scripted readings one per call; nil once exhausted.
private final class Readings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool?]
    init(_ items: [Bool?]) { self.items = items }
    func next() -> Bool? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
}

@Suite struct TeamsMicMonitorTests {
    /// Polls once per reading and returns what `onChange` reported.
    private func run(_ readings: [Bool?], expecting count: Int) async -> [Bool] {
        let script = Readings(readings)
        let log = Log<Bool>()
        let monitor = TeamsMicMonitor(read: { script.next() }, onChange: { log.append($0) })
        for _ in readings { monitor.poll() }
        _ = await eventually { log.all.count >= count }
        // Brief settle so an unexpected extra report would show up.
        try? await Task.sleep(for: .milliseconds(50))
        return log.all
    }

    @Test func matchesTeamsBundlePrefixRunningInput() {
        #expect(TeamsMicMonitor.teamsHoldsMic([
            .init(bundleID: "com.microsoft.teams2.modulehost", isRunningInput: true)]))
        #expect(TeamsMicMonitor.teamsHoldsMic([
            .init(bundleID: "com.microsoft.teams2.helper", isRunningInput: true)]))
    }

    @Test func ignoresOutputOnlyAndOtherApps() {
        #expect(!TeamsMicMonitor.teamsHoldsMic([
            .init(bundleID: "com.microsoft.teams2.helper", isRunningInput: false),
            .init(bundleID: "us.zoom.xos", isRunningInput: true),
            .init(bundleID: "", isRunningInput: true),
            .init(bundleID: "com.jacobmarchionda.scribe", isRunningInput: true)]))
        #expect(!TeamsMicMonitor.teamsHoldsMic([]))
    }

    @Test func failedInputReadOnTeamsProcessIsUnknown() {
        #expect(TeamsMicMonitor.teamsHoldsMic(rawReads: [
            (bundleID: "com.microsoft.teams2.helper", isRunningInput: nil)]) == nil)
    }

    @Test func failedInputReadOnOtherAppIsIgnored() {
        #expect(TeamsMicMonitor.teamsHoldsMic(rawReads: [
            (bundleID: "us.zoom.xos", isRunningInput: nil),
            (bundleID: "com.microsoft.teams2.helper", isRunningInput: true)]) == true)
        #expect(TeamsMicMonitor.teamsHoldsMic(rawReads: [
            (bundleID: "us.zoom.xos", isRunningInput: nil)]) == false)
    }

    @Test func reportsFirstReadingThenOnlyChanges() async {
        #expect(await run([false, false, true, true, false], expecting: 3) == [false, true, false])
    }

    @Test func failedReadKeepsLastState() async {
        #expect(await run([true, nil, nil, true], expecting: 1) == [true])
    }

    @Test func failedFirstReadReportsNothingUntilASuccess() async {
        #expect(await run([nil, false], expecting: 1) == [false])
    }
}
