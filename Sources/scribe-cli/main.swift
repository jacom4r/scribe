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

default:
    fail(usage)
}
