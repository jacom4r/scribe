import AppKit

/// Status item images. Idle is a template (adapts to menu bar theme);
/// recording is a red filled circle, deliberately not a template.
enum MenuBarIcon {
    static func image(recording: Bool) -> NSImage {
        if recording {
            let base = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base.withSymbolConfiguration(config) ?? base
            image.isTemplate = false
            return image
        }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Scribe")!
        image.isTemplate = true
        return image
    }
}
