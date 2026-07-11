import AppKit
import SwiftUI

final class ReminderListFile: Identifiable, Hashable {
    let fileURL: URL
    var rawText: String
    var reminders: [Reminder]

    init(fileURL: URL, rawText: String) {
        self.fileURL = fileURL
        self.rawText = rawText
        reminders = ReminderTextParser.parse(rawText)
    }

    static func == (lhs: ReminderListFile, rhs: ReminderListFile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var id: String {
        fileURL.path(percentEncoded: false)
    }

    var name: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    var fileName: String {
        fileURL.lastPathComponent
    }

}

struct ReminderFocusRequest: Identifiable {
    let id = UUID()
    let listID: ReminderListFile.ID
    let reminderID: Reminder.ID
}

struct ReminderSearchRequest: Identifiable {
    let id = UUID()
    let listID: ReminderListFile.ID
}

struct Reminder: Identifiable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable, Identifiable {
        case todo = "TODO"
        case done = "DONE"
        case canceled = "CANCELED"
        case deleted = "DELETED"

        var id: Self { self }

        var displayName: String {
            switch self {
            case .todo:
                return "Todo"
            case .done:
                return "Done"
            case .canceled:
                return "Cancelled"
            case .deleted:
                return "Deleted"
            }
        }

        var next: Self {
            switch self {
            case .todo:
                return .done
            case .done:
                return .canceled
            case .canceled:
                return .todo
            case .deleted:
                return .todo
            }
        }
    }

    let id: String
    var createTime: String
    var deadline: String
    var level: Int
    var status: Status
    var priorityID: String
    var text: String
    var images: [ReminderImageAttachment]

    var title: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名事项" : trimmed
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case source = "TXT"
    case preview = "预览"

    var id: String { rawValue }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct PriorityDefinition: Identifiable, Hashable {
    static let urgent = PriorityDefinition(id: "urgent", name: "紧急", colorHex: "#FF3B30")
    static let normal = PriorityDefinition(id: "normal", name: "普通", colorHex: "#000000")
    static let hold = PriorityDefinition(id: "hold", name: "Hold", colorHex: "#CCCCCC")
    static let defaults = [urgent, normal, hold]

    let id: String
    var name: String
    var colorHex: String
    var isBold: Bool
    var isUnderlined: Bool
    var isItalic: Bool

    init(
        id: String,
        name: String,
        colorHex: String,
        isBold: Bool = false,
        isUnderlined: Bool = false,
        isItalic: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isBold = isBold
        self.isUnderlined = isUnderlined
        self.isItalic = isItalic
    }

    var encodedValue: String {
        "\(id)|\(name)|\(colorHex)|\(isBold)|\(isUnderlined)|\(isItalic)"
    }

    init?(encodedValue: String) {
        let components = encodedValue.split(separator: "|", maxSplits: 5).map(String.init)
        guard components.count >= 3, !components[0].isEmpty, !components[1].isEmpty else {
            return nil
        }

        self.init(
            id: components[0],
            name: components[1],
            colorHex: components[2],
            isBold: components.count > 3 ? components[3] == "true" : false,
            isUnderlined: components.count > 4 ? components[4] == "true" : false,
            isItalic: components.count > 5 ? components[5] == "true" : false
        )
    }

    var color: Color {
        Color(nsColor: NSColor(hex: colorHex))
    }

    var font: NSFont {
        var result = ReminderEditorMetrics.font
        var traits: NSFontTraitMask = []

        if isBold {
            traits.insert(.boldFontMask)
        }
        if isItalic {
            traits.insert(.italicFontMask)
        }

        if !traits.isEmpty {
            result = NSFontManager.shared.convert(result, toHaveTrait: traits)
        }

        return result
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: value)
        var rgb: UInt64 = 0

        guard scanner.scanHexInt64(&rgb), value.count == 6 else {
            self.init(calibratedWhite: 0, alpha: 1)
            return
        }

        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

enum ReminderAttribute: String, CaseIterable, Identifiable, Hashable {
    case time
    case tag
    case priority

    var id: Self { self }

    var displayName: String {
        switch self {
        case .time:
            return "时间"
        case .tag:
            return "标签"
        case .priority:
            return "优先级"
        }
    }
}
