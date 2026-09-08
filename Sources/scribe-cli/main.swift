import Foundation
import ScribeCore

let usage = "usage: scribe-cli tap | devices | record <seconds> [directory]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "tap":
    do {
        let tap = try ProcessTap()
        print("Tap created: id=\(tap.objectID) uid=\(tap.uid)")
        print("Tap format: \(tap.format.mSampleRate) Hz, \(tap.format.mChannelsPerFrame) ch, bits=\(tap.format.mBitsPerChannel)")
    } catch {
        fail("tap failed: \(error)")
    }

case "devices":
    do {
        let tap = try ProcessTap()
        let aggregate = try AggregateDevice(tap: tap)
        print("Mic: \(aggregate.micName)")
        print("Aggregate device id=\(aggregate.deviceID) rate=\(aggregate.sampleRate) Hz")
        print("Layout: mic buffers=\(aggregate.layout.micBuffers) system buffers=\(aggregate.layout.systemBuffers)")
    } catch {
        fail("devices failed: \(error)")
    }

case "record":
    guard args.count >= 2, let seconds = Double(args[1]), seconds > 0 else { fail(usage) }
    let directory = URL(fileURLWithPath: args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath, isDirectory: true)
    let url = directory.appendingPathComponent("scribe-\(Int(Date().timeIntervalSince1970)).wav")
    do {
        let tap = try ProcessTap()
        let aggregate = try AggregateDevice(tap: tap)
        print("Mic: \(aggregate.micName) @ \(aggregate.sampleRate) Hz; layout mic=\(aggregate.layout.micBuffers) system=\(aggregate.layout.systemBuffers)")

        let writer = try WavWriter(url: url, inputSampleRate: aggregate.sampleRate)
        let relay = InterruptionRelay()
        relay.handler = { error in fail("interrupted: \(error.userMessage)") }
        let engine = CaptureEngine(deviceID: aggregate.deviceID, layout: aggregate.layout, writer: writer, relay: relay)

        try engine.start()
        print("Recording \(Int(seconds))s to \(url.path) ... speak into the mic and play some audio.")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        engine.stop()
        try writer.close()
        print("Saved \(url.path)")
    } catch {
        fail("record failed: \(error)")
    }

default:
    fail(usage)
}
