import AppKit

enum ReminderCopySound {
    private static let sound: NSSound? = {
        guard let url = Bundle.module.url(
            forResource: "Bottle",
            withExtension: "aiff",
            subdirectory: "Resources"
        ) else {
            return nil
        }

        return NSSound(contentsOf: url, byReference: true)
    }()

    static func play() {
        sound?.stop()
        sound?.play()
    }
}
