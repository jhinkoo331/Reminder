import AppKit
import SwiftUI

struct ReminderImageAttachment: Codable, Hashable, Identifiable {
    let path: String
    var displayScale: Int

    var id: String { path }
}

struct ReminderClipboardImage {
    let data: Data
    let suggestedFileName: String?
}

enum ReminderClipboardImageReader {
    static func read(from pasteboard: NSPasteboard = .general) -> ReminderClipboardImage? {
        if let url = fileURL(from: pasteboard),
           NSImage(contentsOf: url) != nil,
           let data = try? Data(contentsOf: url) {
            return ReminderClipboardImage(data: data, suggestedFileName: url.lastPathComponent)
        }

        if let data = pasteboard.data(forType: .png), NSImage(data: data) != nil {
            return ReminderClipboardImage(data: data, suggestedFileName: nil)
        }

        guard let tiffData = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return ReminderClipboardImage(data: pngData, suggestedFileName: nil)
    }

    private static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let value = pasteboard.string(forType: .fileURL) else {
            return nil
        }

        return URL(string: value)
    }
}

struct ReminderImageAttachmentsView: View {
    private static let imageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    let attachments: [ReminderImageAttachment]
    let assetsDirectoryURL: URL?
    let onRemove: (ReminderImageAttachment) -> Void
    let onSetScale: (ReminderImageAttachment, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                if let image = image(for: attachment) {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: imageWidth(for: attachment), alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contextMenu {
                                Button {
                                    onSetScale(attachment, nextSmallerScale(for: attachment.displayScale))
                                } label: {
                                    Label("缩小", systemImage: "arrow.down.right.and.arrow.up.left")
                                }

                                Button {
                                    onSetScale(attachment, nextLargerScale(for: attachment.displayScale))
                                } label: {
                                    Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                                }

                                Menu("显示比例") {
                                    ForEach(displayScales, id: \.self) { scale in
                                        Button("\(scale)%") {
                                            onSetScale(attachment, scale)
                                        }
                                    }
                                }

                                Divider()

                                Button(role: .destructive) {
                                    onRemove(attachment)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                        Text("移除图片")
                                    }
                                }
                            }

                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white, .black.opacity(0.55))
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .padding(6)
                        .help("移除图片")
                    }
                } else {
                    Label("找不到图片：\(attachment.path)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func image(for attachment: ReminderImageAttachment) -> NSImage? {
        guard let assetsDirectoryURL else {
            return nil
        }

        let imageURL = assetsDirectoryURL.appendingPathComponent(attachment.path)
        let cacheKey = imageURL as NSURL
        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let image = NSImage(contentsOf: imageURL) else {
            return nil
        }

        let estimatedCost = Int(image.size.width * image.size.height * 4)
        Self.imageCache.setObject(image, forKey: cacheKey, cost: estimatedCost)
        return image
    }

    private func imageWidth(for attachment: ReminderImageAttachment) -> CGFloat {
        480 * CGFloat(min(max(attachment.displayScale, 25), 200)) / 100
    }

    private var displayScales: [Int] {
        [25, 50, 75, 100, 150, 200]
    }

    private func nextLargerScale(for scale: Int) -> Int {
        displayScales.first(where: { $0 > scale }) ?? displayScales.last ?? scale
    }

    private func nextSmallerScale(for scale: Int) -> Int {
        displayScales.last(where: { $0 < scale }) ?? displayScales.first ?? scale
    }
}

extension ReminderWorkspace {
    func assetsDirectoryURL(for listID: ReminderListFile.ID) -> URL? {
        guard let list = lists.first(where: { $0.id == listID }) else {
            return nil
        }

        return assetsDirectoryURL(forListName: list.name)
    }

    func imageDirectoryURL(for listID: ReminderListFile.ID) -> URL? {
        guard let list = lists.first(where: { $0.id == listID }) else {
            return nil
        }

        return imageDirectoryURL(forListName: list.name)
    }

    func insertClipboardImage(_ image: ReminderClipboardImage, into reminderID: Reminder.ID, in listID: ReminderListFile.ID) {
        guard let listIndex = lists.firstIndex(where: { $0.id == listID }) else {
            return
        }

        let list = lists[listIndex]
        var reminders = list.reminders
        guard let reminderIndex = reminders.firstIndex(where: { $0.id == reminderID }),
              let directoryURL = imageDirectoryURL(forListName: list.name)
        else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let destinationURL = uniqueImageURL(
                suggestedFileName: image.suggestedFileName,
                in: directoryURL
            )
            try image.data.write(to: destinationURL, options: .atomic)
            reminders[reminderIndex].images.append(
                ReminderImageAttachment(
                    path: "images/\(destinationURL.lastPathComponent)",
                    displayScale: 100
                )
            )
            updateReminders(for: listID, reminders: reminders)
        } catch {
            errorMessage = "添加图片失败：\(error.localizedDescription)"
        }
    }

    func removeImage(_ image: ReminderImageAttachment, from reminderID: Reminder.ID, in listID: ReminderListFile.ID) {
        guard let listIndex = lists.firstIndex(where: { $0.id == listID }) else {
            return
        }

        let list = lists[listIndex]
        var reminders = list.reminders
        guard let reminderIndex = reminders.firstIndex(where: { $0.id == reminderID }) else {
            return
        }

        reminders[reminderIndex].images.removeAll { $0.path == image.path }
        let isStillReferenced = reminders.contains { reminder in
            reminder.images.contains { $0.path == image.path }
        }
        updateReminders(for: listID, reminders: reminders)

        guard !isStillReferenced,
              let imagesDirectoryURL = imageDirectoryURL(forListName: list.name)
        else {
            return
        }

        let fileURL = imagesDirectoryURL.deletingLastPathComponent().appendingPathComponent(image.path)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
        } catch {
            errorMessage = "移入图片废纸篓失败：\(error.localizedDescription)"
        }
    }

    func setImageScale(_ scale: Int, for image: ReminderImageAttachment, in reminderID: Reminder.ID, listID: ReminderListFile.ID) {
        guard let listIndex = lists.firstIndex(where: { $0.id == listID }) else {
            return
        }

        var reminders = lists[listIndex].reminders
        guard let reminderIndex = reminders.firstIndex(where: { $0.id == reminderID }),
              let imageIndex = reminders[reminderIndex].images.firstIndex(where: { $0.path == image.path })
        else {
            return
        }

        reminders[reminderIndex].images[imageIndex].displayScale = min(max(scale, 25), 200)
        updateReminders(for: listID, reminders: reminders)
    }

    func assetsDirectoryURL(forListName listName: String) -> URL? {
        workDirectoryURL?
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(listName, isDirectory: true)
    }

    private func imageDirectoryURL(forListName listName: String) -> URL? {
        assetsDirectoryURL(forListName: listName)?
            .appendingPathComponent("images", isDirectory: true)
    }

    private func uniqueImageURL(suggestedFileName: String?, in directoryURL: URL) -> URL {
        let cleanedName = sanitizedImageFileName(suggestedFileName)
        let baseName = (cleanedName as NSString).deletingPathExtension
        let fileExtension = (cleanedName as NSString).pathExtension
        var candidateURL = directoryURL.appendingPathComponent(cleanedName)
        var suffix = 1

        while FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
            let name = "\(baseName) (\(suffix)).\(fileExtension)"
            candidateURL = directoryURL.appendingPathComponent(name)
            suffix += 1
        }

        return candidateURL
    }

    private func sanitizedImageFileName(_ suggestedFileName: String?) -> String {
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let fallback = "图片 \(fallbackFormatter.string(from: Date())).png"
        let originalName = suggestedFileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileName = originalName?.isEmpty == false ? originalName! : fallback
        let baseName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        return "\(baseName.isEmpty ? "图片" : baseName).\(fileExtension.isEmpty ? "png" : fileExtension)"
    }
}
