import Foundation
import ScribeCore
import ScribeTranscription

let usage = "usage: scribe-cli tap | devices | record <seconds> [directory] | transcribe <wav>"

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
    let session = RecordingSession(store: RecordingStore(directory: directory))
    session.onInterrupted = { error, url in
        fail("interrupted: \(error.userMessage) (partial file at \(url.path))")
    }
    do {
        let url = try session.start()
        print("Recording \(Int(seconds))s to \(url.path) ... speak into the mic and play some audio.")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        try session.stop()
        print("Saved \(url.path)")
    } catch {
        fail("record failed: \(error)")
    }

case "transcribe":
    guard args.count == 2 else { fail(usage) }
    let wavURL = URL(fileURLWithPath: args[1])
    Task {
        do {
            let engine = FluidAudioEngine()
            var started = Date()
            try await engine.prepare()
            FileHandle.standardError.write(Data(String(format: "models ready in %.1f s\n", Date().timeIntervalSince(started)).utf8))

            started = Date()
            let out = try await TranscriptionPipeline(engine: engine).run(wavURL)
            FileHandle.standardError.write(Data(String(format: "transcribed in %.1f s\n", Date().timeIntervalSince(started)).utf8))
            print(out.path)
            exit(0)
        } catch {
            fail("transcribe failed: \((error as? ScribeError)?.userMessage ?? "\(error)")")
        }
    }
    RunLoop.main.run()

default:
    fail(usage)
}
