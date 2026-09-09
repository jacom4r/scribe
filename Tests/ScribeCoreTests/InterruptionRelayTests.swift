import Foundation
import Testing

@testable import ScribeCore

/// Collects handler deliveries. Main-actor isolated — and therefore
/// implicitly `Sendable` — so the relay's `@Sendable` handler can capture it
/// and record from the main queue where the relay always delivers.
@MainActor
private final class Deliveries {
    var errors: [ScribeError] = []
    var onMainThread: [Bool] = []
}

@MainActor
@Suite struct InterruptionRelayTests {
    /// The relay coalesces to the first error and hops to the main queue, so
    /// the audio thread's failure path can call it freely.
    @Test func deliversFirstErrorOnceOnTheMainThread() async throws {
        let relay = InterruptionRelay()
        let deliveries = Deliveries()

        relay.handler = { error in
            // The relay dispatches to `DispatchQueue.main`, so this really is
            // the main actor's executor even though the closure is nonisolated.
            let isMain = Thread.isMainThread
            MainActor.assumeIsolated {
                deliveries.errors.append(error)
                deliveries.onMainThread.append(isMain)
            }
        }

        DispatchQueue.global().async {
            relay.fire(.writeFailed(-1))
            relay.fire(.writeFailed(-1))
            relay.fire(.inputDeviceChanged)
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(deliveries.errors == [.writeFailed(-1)])
        #expect(deliveries.onMainThread == [true])
    }
}
