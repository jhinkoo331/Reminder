import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension ReminderWorkspace {
    func exportSelectedListAsPDF() {
        guard let selectedListID,
              let list = lists.first(where: { $0.id == selectedListID })
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(list.name).pdf"
        panel.title = "Export as PDF"
        panel.message = "导出“\(list.name)”中的全部任务"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try ReminderPDFExporter.write(
                listName: list.name,
                reminders: list.reminders,
                priorities: defaultPriorities + customPriorities,
                visibleAttributes: visibleReminderAttributes,
                showsTaskNumbers: showsTaskNumbers,
                assetsDirectoryURL: assetsDirectoryURL(for: selectedListID),
                to: destinationURL
            )
        } catch {
            errorMessage = "导出 PDF 失败：\(error.localizedDescription)"
        }
    }
}

enum ReminderPDFExporter {
    private static let pageSize = NSSize(width: 595, height: 842) // A4 at 72 dpi
    private static let horizontalMargin: CGFloat = 38
    private static let topMargin: CGFloat = 42
    private static let bottomMargin: CGFloat = 38
    private static let rowSpacing: CGFloat = 14

    static func write(
        listName: String,
        reminders: [Reminder],
        priorities: [PriorityDefinition],
        visibleAttributes: Set<ReminderAttribute>,
        showsTaskNumbers: Bool,
        assetsDirectoryURL: URL?,
        to destinationURL: URL
    ) throws {
        guard let context = CGContext(destinationURL as CFURL, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let priorityMap = Dictionary(uniqueKeysWithValues: priorities.map { ($0.id, $0) })
        let taskNumbers = showsTaskNumbers ? makeTaskNumbers(for: reminders) : [:]
        let renderer = Renderer(
            context: context,
            listName: listName,
            priorityMap: priorityMap,
            visibleAttributes: visibleAttributes,
            taskNumbers: taskNumbers,
            assetsDirectoryURL: assetsDirectoryURL
        )

        renderer.beginPage()
        for reminder in reminders {
            renderer.draw(reminder: reminder)
        }
        renderer.endPage()
        context.closePDF()
    }

    private static func makeTaskNumbers(for reminders: [Reminder]) -> [Reminder.ID: String] {
        var counters: [Int] = []
        var numbers: [Reminder.ID: String] = [:]

        for reminder in reminders {
            let level = min(max(reminder.level, 1), counters.count + 1)
            if counters.count < level {
                counters.append(contentsOf: repeatElement(0, count: level - counters.count))
            } else if counters.count > level {
                counters.removeLast(counters.count - level)
            }
            counters[level - 1] += 1
            numbers[reminder.id] = counters.map(String.init).joined(separator: ".")
        }

        return numbers
    }

    private final class Renderer {
        private let context: CGContext
        private let listName: String
        private let priorityMap: [String: PriorityDefinition]
        private let visibleAttributes: Set<ReminderAttribute>
        private let taskNumbers: [Reminder.ID: String]
        private let assetsDirectoryURL: URL?
        private var pageNumber = 0
        private var cursorY: CGFloat = 0

        private var contentWidth: CGFloat {
            pageSize.width - horizontalMargin * 2
        }

        init(
            context: CGContext,
            listName: String,
            priorityMap: [String: PriorityDefinition],
            visibleAttributes: Set<ReminderAttribute>,
            taskNumbers: [Reminder.ID: String],
            assetsDirectoryURL: URL?
        ) {
            self.context = context
            self.listName = listName
            self.priorityMap = priorityMap
            self.visibleAttributes = visibleAttributes
            self.taskNumbers = taskNumbers
            self.assetsDirectoryURL = assetsDirectoryURL
        }

        func beginPage() {
            pageNumber += 1
            let pageInfo = [
                kCGPDFContextMediaBox: CGRect(origin: .zero, size: pageSize)
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

            let title = NSAttributedString(
                string: listName,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 20, weight: .bold),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            title.draw(at: NSPoint(x: horizontalMargin, y: topMargin))

            let subtitle = NSAttributedString(
                string: "任务列表导出",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            subtitle.draw(at: NSPoint(x: horizontalMargin, y: topMargin + 27))
            cursorY = topMargin + 50
        }

        func endPage() {
            let footer = NSAttributedString(
                string: "\(listName)  ·  \(pageNumber)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            footer.draw(at: NSPoint(x: horizontalMargin, y: pageSize.height - bottomMargin + 10))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }

        func draw(reminder: Reminder) {
            let priority = priorityMap[reminder.priorityID] ?? .normal
            let layout = rowLayout(for: reminder, priority: priority)
            let availableHeight = pageSize.height - bottomMargin - cursorY

            if layout.height <= pageSize.height - topMargin - bottomMargin - 50,
               layout.height > availableHeight {
                endPage()
                beginPage()
            }

            drawStatus(reminder.status, at: NSPoint(x: layout.leadingX, y: cursorY + 2))
            drawAttributes(for: reminder, priority: priority, at: NSPoint(x: layout.leadingX + 22, y: cursorY))

            let textOrigin = NSPoint(x: layout.textX, y: cursorY)
            layout.text.draw(in: NSRect(x: textOrigin.x, y: textOrigin.y, width: layout.textWidth, height: layout.textHeight))
            cursorY += layout.textHeight + 8

            for imageLayout in layout.images {
                if cursorY + imageLayout.size.height > pageSize.height - bottomMargin {
                    endPage()
                    beginPage()
                }
                imageLayout.image.draw(
                    in: NSRect(x: layout.textX, y: cursorY, width: imageLayout.size.width, height: imageLayout.size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                cursorY += imageLayout.size.height + 8
            }

            cursorY += rowSpacing
        }

        private func rowLayout(for reminder: Reminder, priority: PriorityDefinition) -> RowLayout {
            let indentation = CGFloat(max(reminder.level - 1, 0)) * 22
            let leadingX = horizontalMargin + indentation
            let attributeWidth = attributesWidth(for: reminder, priority: priority)
            let number = taskNumbers[reminder.id]
            let numberWidth = number.map { measure($0, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular)).width + 7 } ?? 0
            let textX = leadingX + 22 + attributeWidth + numberWidth
            let textWidth = max(120, pageSize.width - horizontalMargin - textX)
            let text = styledText(for: reminder, priority: priority)
            let textHeight = ceil(text.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
            let images = imageLayouts(for: reminder, maximumWidth: textWidth)
            let imageHeight = images.reduce(CGFloat(0)) { $0 + $1.size.height + 8 }

            return RowLayout(
                leadingX: leadingX,
                textX: textX,
                textWidth: textWidth,
                text: text,
                textHeight: max(18, textHeight),
                images: images,
                height: max(18, textHeight) + 8 + imageHeight + rowSpacing
            )
        }

        private func styledText(for reminder: Reminder, priority: PriorityDefinition) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            let attributes: [NSAttributedString.Key: Any] = [
                .font: priority.font,
                .foregroundColor: NSColor(hex: priority.colorHex),
                .paragraphStyle: paragraph,
                .underlineStyle: priority.isUnderlined ? NSUnderlineStyle.single.rawValue : 0,
                .strikethroughStyle: reminder.status == .canceled || reminder.status == .deleted
                    ? NSUnderlineStyle.single.rawValue : 0
            ]
            return NSAttributedString(string: reminder.text, attributes: attributes)
        }

        private func attributesWidth(for reminder: Reminder, priority: PriorityDefinition) -> CGFloat {
            var width: CGFloat = 0
            if visibleAttributes.contains(.time) {
                width += measure(displayTime(for: reminder), font: .systemFont(ofSize: 10)).width + 10
            }
            if visibleAttributes.contains(.priority) {
                width += measure(priority.name, font: .systemFont(ofSize: 10)).width + 12
            }
            return width
        }

        private func drawAttributes(for reminder: Reminder, priority: PriorityDefinition, at point: NSPoint) {
            var x = point.x
            if visibleAttributes.contains(.time) {
                let title = displayTime(for: reminder)
                let size = measure(title, font: .systemFont(ofSize: 10))
                drawBadge(title, at: NSPoint(x: x, y: point.y), width: size.width + 10, color: .controlBackgroundColor)
                x += size.width + 10
            }
            if visibleAttributes.contains(.priority) {
                let size = measure(priority.name, font: .systemFont(ofSize: 10))
                drawBadge(priority.name, at: NSPoint(x: x, y: point.y), width: size.width + 12, color: NSColor(hex: priority.colorHex).withAlphaComponent(0.12), textColor: NSColor(hex: priority.colorHex))
            }
        }

        private func drawBadge(_ title: String, at point: NSPoint, width: CGFloat, color: NSColor, textColor: NSColor = .secondaryLabelColor) {
            let rect = NSRect(x: point.x, y: point.y + 1, width: width, height: 16)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: textColor
            ]).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 3))
        }

        private func drawStatus(_ status: Reminder.Status, at point: NSPoint) {
            let rect = NSRect(x: point.x, y: point.y, width: 14, height: 14)
            let path = NSBezierPath(ovalIn: rect)
            let color: NSColor
            switch status {
            case .todo:
                color = .secondaryLabelColor
                color.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            case .workingOn:
                color = .systemBlue
                color.setFill()
                path.fill()
            case .done:
                color = .systemGreen
                color.setFill()
                path.fill()
                drawCheckmark(in: rect)
            case .canceled:
                color = .systemOrange
                color.setFill()
                path.fill()
            case .deleted:
                color = .systemRed
                color.setFill()
                path.fill()
            }
        }

        private func drawCheckmark(in rect: NSRect) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX - 1, y: rect.maxY - 3))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 3))
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }

        private func imageLayouts(for reminder: Reminder, maximumWidth: CGFloat) -> [ImageLayout] {
            guard let assetsDirectoryURL else { return [] }
            return reminder.images.compactMap { attachment in
                let url = assetsDirectoryURL.appendingPathComponent(attachment.path)
                guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
                    return nil
                }
                let desiredWidth = 480 * CGFloat(min(max(attachment.displayScale, 25), 200)) / 100
                let width = min(desiredWidth, maximumWidth)
                let maximumHeight = pageSize.height - topMargin - bottomMargin - 90
                let height = min(width * image.size.height / image.size.width, maximumHeight)
                return ImageLayout(image: image, size: NSSize(width: width, height: height))
            }
        }

        private func displayTime(for reminder: Reminder) -> String {
            let input = DateFormatter()
            input.locale = Locale(identifier: "zh_CN")
            input.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard let date = input.date(from: reminder.deadline) else { return reminder.deadline }
            input.dateFormat = "MM-dd HH:mm"
            return input.string(from: date)
        }

        private func measure(_ text: String, font: NSFont) -> NSSize {
            NSAttributedString(string: text, attributes: [.font: font]).size()
        }
    }

    private struct RowLayout {
        let leadingX: CGFloat
        let textX: CGFloat
        let textWidth: CGFloat
        let text: NSAttributedString
        let textHeight: CGFloat
        let images: [ImageLayout]
        let height: CGFloat
    }

    private struct ImageLayout {
        let image: NSImage
        let size: NSSize
    }
}
