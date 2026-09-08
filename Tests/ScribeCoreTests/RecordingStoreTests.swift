import Foundation
import Testing
@testable import ScribeCore

@Suite struct RecordingStoreTests {
    private func tempStore() -> RecordingStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Scribe", isDirectory: true)
        return RecordingStore(directory: dir)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func createsDirectoryAndNamesFile() throws {
        let store = tempStore()
        let url = try store.newRecordingURL(at: date(2026, 9, 7, 14, 32))

        #expect(url.lastPathComponent == "2026-09-07 14-32 Recording.wav")
        #expect(url.deletingLastPathComponent().path == store.directory.path)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func suffixesOnCollision() throws {
        let store = tempStore()
        let d = date(2026, 9, 7, 14, 32)

        let first = try store.newRecordingURL(at: d)
        try Data().write(to: first)
        let second = try store.newRecordingURL(at: d)
        #expect(second.lastPathComponent == "2026-09-07 14-32 Recording (2).wav")

        try Data().write(to: second)
        let third = try store.newRecordingURL(at: d)
        #expect(third.lastPathComponent == "2026-09-07 14-32 Recording (3).wav")
    }

    @Test func defaultStoreIsMusicScribe() {
        let store = RecordingStore.default()
        #expect(store.directory.path.hasSuffix("/Music/Scribe"))
    }
}
