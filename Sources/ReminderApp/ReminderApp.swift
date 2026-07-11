import AppKit
import SwiftUI

@main
struct ReminderApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = ReminderWorkspace()

    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                ContentView()
                    .frame(
                        width: geometry.size.width / workspace.interfaceScale,
                        height: geometry.size.height / workspace.interfaceScale
                    )
                    .scaleEffect(workspace.interfaceScale, anchor: .topLeading)
            }
            .environmentObject(workspace)
            .preferredColorScheme(workspace.colorMode.colorScheme)
            .frame(minWidth: 840, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("保存当前列表") {
                    workspace.saveSelectedList()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspace.selectedListID == nil)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    workspace.undoLastChange()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!workspace.canUndo)

                Button("重做") {
                    workspace.redoLastChange()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
                .disabled(!workspace.canRedo)
            }

            CommandGroup(replacing: .newItem) {
                Button("新建任务") {
                    workspace.addTopLevelReminder()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace.selectedListID == nil)
            }

            CommandGroup(after: .toolbar) {
                Button("搜索") {
                    workspace.requestSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace.selectedListID == nil || workspace.displayMode != .preview)

                Divider()

                Button("放大") {
                    workspace.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("缩小") {
                    workspace.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("实际大小") {
                    workspace.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                ForEach(DisplayMode.allCases) { mode in
                    Toggle(
                        mode.rawValue,
                        isOn: Binding(
                            get: { workspace.displayMode == mode },
                            set: { isSelected in
                                if isSelected {
                                    workspace.setDisplayMode(mode)
                                }
                            }
                        )
                    )
                }

                Divider()

                ForEach(ReminderAttribute.allCases) { attribute in
                    Toggle(
                        "显示\(attribute.displayName)",
                        isOn: Binding(
                            get: { workspace.visibleReminderAttributes.contains(attribute) },
                            set: { workspace.setReminderAttribute(attribute, visible: $0) }
                        )
                    )
                }

                Divider()

                ForEach(Reminder.Status.allCases) { status in
                    Toggle(
                        "显示 \(status.displayName)",
                        isOn: Binding(
                            get: { workspace.visibleReminderStatuses.contains(status) },
                            set: { workspace.setReminderStatus(status, visible: $0) }
                        )
                    )
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(workspace)
                .preferredColorScheme(workspace.colorMode.colorScheme)
                .frame(width: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyDownMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  event.keyCode == 3
            else {
                return event
            }

            NotificationCenter.default.post(name: .reminderFindRequested, object: nil)
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
    }
}

extension Notification.Name {
    static let reminderFindRequested = Notification.Name("ReminderFindRequested")
}

@MainActor
final class ReminderWorkspace: ObservableObject {
    @Published var workDirectoryURL: URL?
    @Published var lists: [ReminderListFile] = []
    @Published var selectedListID: ReminderListFile.ID?
    @Published var displayMode: DisplayMode = .preview
    @Published var colorMode: ColorMode = .system
    @Published var interfaceScale: CGFloat = 1
    @Published var defaultPriorities: [PriorityDefinition] = PriorityDefinition.defaults
    @Published var customPriorities: [PriorityDefinition] = []
    @Published var visibleReminderAttributes: Set<ReminderAttribute> = []
    @Published var visibleReminderStatuses: Set<Reminder.Status> = [.todo, .done, .canceled]
    @Published var focusRequest: ReminderFocusRequest?
    @Published var searchRequest: ReminderSearchRequest?
    @Published var errorMessage: String?

    private let workDirectoryDefaultsKey = "ReminderWorkDirectoryPath"
    private let configurationFileName = "config.yaml"
    private let undoManager = UndoManager()

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    init() {
        restoreWorkDirectory()
    }

    var selectedListIndex: Int? {
        if let selectedListID,
           let index = lists.firstIndex(where: { $0.id == selectedListID }) {
            return index
        }

        return lists.indices.first
    }

    func setReminderAttribute(_ attribute: ReminderAttribute, visible: Bool) {
        var attributes = visibleReminderAttributes

        if visible {
            attributes.insert(attribute)
        } else {
            attributes.remove(attribute)
        }

        visibleReminderAttributes = attributes
        persistConfiguration()
    }

    func setDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        persistConfiguration()
    }

    func setColorMode(_ mode: ColorMode) {
        colorMode = mode
        persistConfiguration()
    }

    func requestSearch() {
        guard let selectedListID, displayMode == .preview else {
            return
        }

        searchRequest = ReminderSearchRequest(listID: selectedListID)
    }

    func zoomIn() {
        setInterfaceScale(interfaceScale + 0.1)
    }

    func zoomOut() {
        setInterfaceScale(interfaceScale - 0.1)
    }

    func resetZoom() {
        setInterfaceScale(1)
    }

    private func setInterfaceScale(_ scale: CGFloat) {
        interfaceScale = min(max((scale * 10).rounded() / 10, 0.7), 1.6)
        persistConfiguration()
    }

    func setReminderStatus(_ status: Reminder.Status, visible: Bool) {
        var statuses = visibleReminderStatuses

        if visible {
            statuses.insert(status)
        } else {
            statuses.remove(status)
        }

        visibleReminderStatuses = statuses
        persistConfiguration()
    }

    var priorityDefinitions: [PriorityDefinition] {
        defaultPriorities + customPriorities
    }

    func priorityDefinition(for id: String) -> PriorityDefinition {
        priorityDefinitions.first { $0.id == id } ?? PriorityDefinition.normal
    }

    func addCustomPriority() {
        customPriorities.append(
            PriorityDefinition(
                id: "custom-\(UUID().uuidString)",
                name: "自定义优先级",
                colorHex: "#007AFF"
            )
        )
        persistConfiguration()
    }

    func updateCustomPriority(id: String, name: String, colorHex: String) {
        updatePriority(id: id, name: name, colorHex: colorHex)
    }

    func updatePriority(
        id: String,
        name: String? = nil,
        colorHex: String? = nil,
        isBold: Bool? = nil,
        isUnderlined: Bool? = nil,
        isItalic: Bool? = nil
    ) {
        if let index = defaultPriorities.firstIndex(where: { $0.id == id }) {
            applyPriorityChanges(
                to: &defaultPriorities[index],
                name: nil,
                colorHex: colorHex,
                isBold: isBold,
                isUnderlined: isUnderlined,
                isItalic: isItalic
            )
        } else if let index = customPriorities.firstIndex(where: { $0.id == id }) {
            applyPriorityChanges(
                to: &customPriorities[index],
                name: name,
                colorHex: colorHex,
                isBold: isBold,
                isUnderlined: isUnderlined,
                isItalic: isItalic
            )
        } else {
            return
        }

        persistConfiguration()
    }

    private func applyPriorityChanges(
        to priority: inout PriorityDefinition,
        name: String?,
        colorHex: String?,
        isBold: Bool?,
        isUnderlined: Bool?,
        isItalic: Bool?
    ) {
        if let name {
            priority.name = name.replacingOccurrences(of: "|", with: " ")
        }
        if let colorHex {
            priority.colorHex = colorHex
        }
        if let isBold {
            priority.isBold = isBold
        }
        if let isUnderlined {
            priority.isUnderlined = isUnderlined
        }
        if let isItalic {
            priority.isItalic = isItalic
        }
    }

    func removeCustomPriority(id: String) {
        customPriorities.removeAll { $0.id == id }
        persistConfiguration()
    }

    func addTopLevelReminder() {
        guard let selectedListID,
              let listIndex = lists.firstIndex(where: { $0.id == selectedListID })
        else {
            return
        }

        let timestamp = ReminderTextParser.currentTimestamp()
        let reminder = Reminder(
            id: "\(timestamp)-0",
            createTime: timestamp,
            deadline: timestamp,
            level: 1,
            status: .todo,
            priorityID: PriorityDefinition.normal.id,
            parent: nil,
            text: ""
        )
        var reminders = lists[listIndex].reminders
        reminders.insert(reminder, at: 0)
        updateReminders(for: selectedListID, reminders: reminders)
        focusRequest = ReminderFocusRequest(listID: selectedListID, reminderID: reminder.id)
    }

    func undoLastChange() {
        guard undoManager.canUndo else {
            return
        }

        undoManager.undo()
        objectWillChange.send()
    }

    func redoLastChange() {
        guard undoManager.canRedo else {
            return
        }

        undoManager.redo()
        objectWillChange.send()
    }

    func saveSelectedList() {
        guard let selectedListID,
              let index = lists.firstIndex(where: { $0.id == selectedListID })
        else {
            return
        }

        let reminders = lists[index].reminders
        let nonEmptyReminders = reminders.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if nonEmptyReminders.count != reminders.count {
            updateRawText(
                for: selectedListID,
                rawText: ReminderTextParser.serialize(nonEmptyReminders)
            )
        } else {
            saveList(at: index)
        }
    }

    func openConfigurationFile() {
        guard let workDirectoryURL else {
            return
        }

        persistConfiguration()
        let configurationURL = workDirectoryURL.appendingPathComponent(configurationFileName)
        guard NSWorkspace.shared.open(configurationURL) else {
            errorMessage = "无法打开 config.yaml。"
            return
        }
    }

    func openWorkDirectoryInFinder() {
        guard let workDirectoryURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([workDirectoryURL])
    }

    var workDirectoryDisplayPath: String {
        workDirectoryURL?.path(percentEncoded: false) ?? "未设置"
    }

    func promptForWorkDirectoryIfNeeded() {
        guard workDirectoryURL == nil else {
            return
        }

        chooseWorkDirectory()
    }

    func chooseWorkDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Reminder 工作目录"
        panel.message = "该目录下的每个 TXT 文件都会作为一个待办事项列表读取。"
        panel.prompt = "选择目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }

        setWorkDirectory(url)
    }

    func setWorkDirectory(_ url: URL) {
        let directoryURL = url.standardizedFileURL
        workDirectoryURL = directoryURL
        UserDefaults.standard.set(directoryURL.path(percentEncoded: false), forKey: workDirectoryDefaultsKey)
        loadConfiguration()
        reloadLists()
        persistConfiguration()
    }

    func reloadLists() {
        guard let workDirectoryURL else {
            lists = []
            selectedListID = nil
            return
        }

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: workDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            let txtFiles = fileURLs
                .filter { $0.pathExtension.lowercased() == "txt" }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }

            lists = txtFiles.map { fileURL in
                let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                return ReminderListFile(fileURL: fileURL, rawText: text)
            }

            if let selectedListID,
               lists.contains(where: { $0.id == selectedListID }) {
                self.selectedListID = selectedListID
            } else {
                selectedListID = lists.first?.id
            }

            errorMessage = nil
        } catch {
            lists = []
            selectedListID = nil
            errorMessage = "无法读取工作目录：\(error.localizedDescription)"
        }
    }

    func updateRawText(for listID: ReminderListFile.ID, rawText: String) {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else {
            return
        }

        let previousText = lists[index].rawText
        guard previousText != rawText else {
            return
        }

        undoManager.registerUndo(withTarget: self) { workspace in
            workspace.updateRawText(for: listID, rawText: previousText)
        }
        undoManager.setActionName("编辑任务")
        lists[index].rawText = rawText
        saveList(at: index)
    }

    func updateReminders(for listID: ReminderListFile.ID, reminders: [Reminder]) {
        updateRawText(for: listID, rawText: ReminderTextParser.serialize(reminders))
    }

    @discardableResult
    func createList(named requestedName: String) -> Bool {
        guard let workDirectoryURL else {
            errorMessage = "请先选择工作目录。"
            return false
        }

        let fileURL = uniqueTXTFileURL(for: requestedName, in: workDirectoryURL)

        do {
            try "".write(to: fileURL, atomically: true, encoding: .utf8)
            reloadLists()
            selectedListID = fileURL.path(percentEncoded: false)
            return true
        } catch {
            errorMessage = "新建列表失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func renameList(id listID: ReminderListFile.ID, to requestedName: String) -> Bool {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else {
            return false
        }

        let oldURL = lists[index].fileURL
        let newURL = uniqueTXTFileURL(
            for: requestedName,
            in: oldURL.deletingLastPathComponent(),
            excluding: oldURL
        )

        guard oldURL.path(percentEncoded: false) != newURL.path(percentEncoded: false) else {
            return true
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            reloadLists()
            selectedListID = newURL.path(percentEncoded: false)
            return true
        } catch {
            errorMessage = "重命名列表失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteList(id listID: ReminderListFile.ID) -> Bool {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else {
            return false
        }

        let fileURL = lists[index].fileURL

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
            reloadLists()
            if selectedListID == listID {
                selectedListID = lists.first?.id
            }
            return true
        } catch {
            errorMessage = "删除列表失败：\(error.localizedDescription)"
            return false
        }
    }

    private func restoreWorkDirectory() {
        guard let path = UserDefaults.standard.string(forKey: workDirectoryDefaultsKey),
              !path.isEmpty
        else {
            return
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            UserDefaults.standard.removeObject(forKey: workDirectoryDefaultsKey)
            return
        }

        workDirectoryURL = url
        loadConfiguration()
        reloadLists()
        persistConfiguration()
    }

    func persistConfiguration() {
        guard let workDirectoryURL else {
            return
        }

        let configurationURL = workDirectoryURL.appendingPathComponent(configurationFileName)
        let attributes = visibleReminderAttributes
            .map(\.rawValue)
            .sorted()
        let attributeLines = attributes.isEmpty
            ? "visible_attributes: []"
            : "visible_attributes:\n" + attributes.map { "  - \($0)" }.joined(separator: "\n")
        let statuses = visibleReminderStatuses
            .map(\.rawValue)
            .sorted()
        let statusLines = statuses.isEmpty
            ? "visible_statuses: []"
            : "visible_statuses:\n" + statuses.map { "  - \($0)" }.joined(separator: "\n")
        let customPriorityLines = customPriorities.isEmpty
            ? "custom_priorities: []"
            : "custom_priorities:\n" + customPriorities.map { "  - \(yamlQuoted($0.encodedValue))" }.joined(separator: "\n")
        let defaultPriorityLines = "default_priorities:\n" + defaultPriorities
            .map { "  - \(yamlQuoted($0.encodedValue))" }
            .joined(separator: "\n")
        let selectedList = selectedListID.map(yamlQuoted) ?? ""
        let header = configurationHeader(for: configurationURL)
        let content = [
            header,
            "version: 1",
            "work_directory: \(yamlQuoted(workDirectoryURL.path(percentEncoded: false)))",
            "display_mode: \(displayMode.rawValue)",
            "color_mode: \(colorMode.rawValue)",
            "interface_scale: \(String(format: "%.1f", interfaceScale))",
            "selected_list_id: \(selectedList)",
            attributeLines,
            statusLines,
            defaultPriorityLines,
            customPriorityLines,
            ""
        ].joined(separator: "\n")

        do {
            try content.write(
                to: configurationURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = "保存配置失败：\(error.localizedDescription)"
        }
    }

    private func configurationHeader(for configurationURL: URL) -> String {
        let prefix = "# Reminder configuration | Created by: "
        let timestampSeparator = " | Last modified: "
        let creator = (try? String(contentsOf: configurationURL, encoding: .utf8))?
            .components(separatedBy: .newlines)
            .first
            .flatMap { firstLine -> String? in
                guard firstLine.hasPrefix(prefix),
                      let separatorRange = firstLine.range(of: timestampSeparator)
                else {
                    return nil
                }

                return String(firstLine[firstLine.index(firstLine.startIndex, offsetBy: prefix.count)..<separatorRange.lowerBound])
            }
            ?? NSFullUserName()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"

        return "\(prefix)\(creator)\(timestampSeparator)\(formatter.string(from: Date()))"
    }

    private func loadConfiguration() {
        guard let workDirectoryURL else {
            return
        }

        let configurationURL = workDirectoryURL.appendingPathComponent(configurationFileName)
        guard FileManager.default.fileExists(atPath: configurationURL.path(percentEncoded: false)) else {
            return
        }

        do {
            let content = try String(contentsOf: configurationURL, encoding: .utf8)
            var selectedList: String?
            var attributes = Set<ReminderAttribute>()
            var statuses: Set<Reminder.Status> = [.todo, .done, .canceled]
            var priorities: [PriorityDefinition] = []
            var configuredDefaults: [PriorityDefinition] = []
            var isReadingAttributes = false
            var isReadingStatuses = false
            var isReadingPriorities = false
            var isReadingDefaultPriorities = false

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("- "), isReadingAttributes {
                    let rawValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let attribute = ReminderAttribute(rawValue: unquotedYAMLValue(rawValue)) {
                        attributes.insert(attribute)
                    }
                    continue
                }

                if trimmed.hasPrefix("- "), isReadingStatuses {
                    let rawValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let status = Reminder.Status(rawValue: unquotedYAMLValue(rawValue)) {
                        statuses.insert(status)
                    }
                    continue
                }

                if trimmed.hasPrefix("- "), isReadingPriorities {
                    let rawValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let priority = PriorityDefinition(encodedValue: unquotedYAMLValue(rawValue)) {
                        priorities.append(priority)
                    }
                    continue
                }

                if trimmed.hasPrefix("- "), isReadingDefaultPriorities {
                    let rawValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let priority = PriorityDefinition(encodedValue: unquotedYAMLValue(rawValue)) {
                        configuredDefaults.append(priority)
                    }
                    continue
                }

                isReadingAttributes = trimmed == "visible_attributes:"
                isReadingStatuses = trimmed == "visible_statuses:"
                isReadingPriorities = trimmed == "custom_priorities:"
                isReadingDefaultPriorities = trimmed == "default_priorities:"

                if trimmed == "visible_statuses:" || trimmed == "visible_statuses: []" {
                    statuses = []
                }

                if let value = yamlValue(for: "display_mode", in: trimmed),
                   let mode = DisplayMode(rawValue: value) {
                    displayMode = mode
                }

                if let value = yamlValue(for: "color_mode", in: trimmed),
                   let mode = ColorMode(rawValue: value) {
                    colorMode = mode
                }

                if let value = yamlValue(for: "interface_scale", in: trimmed),
                   let scale = Double(value) {
                    interfaceScale = min(max(CGFloat(scale), 0.7), 1.6)
                }

                if let value = yamlValue(for: "selected_list_id", in: trimmed), !value.isEmpty {
                    selectedList = value
                }
            }

            visibleReminderAttributes = attributes
            visibleReminderStatuses = statuses
            defaultPriorities = PriorityDefinition.defaults.map { builtIn in
                guard let configured = configuredDefaults.first(where: { $0.id == builtIn.id }) else {
                    return builtIn
                }

                return PriorityDefinition(
                    id: builtIn.id,
                    name: builtIn.name,
                    colorHex: configured.colorHex,
                    isBold: configured.isBold,
                    isUnderlined: configured.isUnderlined,
                    isItalic: configured.isItalic
                )
            }
            customPriorities = priorities
            selectedListID = selectedList
        } catch {
            errorMessage = "读取配置失败：\(error.localizedDescription)"
        }
    }

    private func yamlValue(for key: String, in line: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else {
            return nil
        }

        return unquotedYAMLValue(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    private func yamlQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func unquotedYAMLValue(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }

        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func saveList(at index: Int) {
        do {
            try lists[index].rawText.write(to: lists[index].fileURL, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func uniqueTXTFileURL(for requestedName: String, in directoryURL: URL, excluding excludedURL: URL? = nil) -> URL {
        let sanitizedName = sanitizedListName(from: requestedName)
        var candidateURL = directoryURL
            .appendingPathComponent(sanitizedName)
            .appendingPathExtension("txt")
            .standardizedFileURL

        let excludedPath = excludedURL?.standardizedFileURL.path(percentEncoded: false)
        if candidateURL.path(percentEncoded: false) == excludedPath {
            return candidateURL
        }

        var suffix = 2
        while FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
            candidateURL = directoryURL
                .appendingPathComponent("\(sanitizedName) \(suffix)")
                .appendingPathExtension("txt")
                .standardizedFileURL

            if candidateURL.path(percentEncoded: false) == excludedPath {
                return candidateURL
            }

            suffix += 1
        }

        return candidateURL
    }

    private func sanitizedListName(from requestedName: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:\\")
        let components = requestedName
            .components(separatedBy: forbiddenCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sanitizedName = components.joined(separator: " ")
        return sanitizedName.isEmpty ? "新建列表" : sanitizedName
    }
}

struct ReminderListFile: Identifiable, Hashable {
    let fileURL: URL
    var rawText: String

    var id: String {
        fileURL.path(percentEncoded: false)
    }

    var name: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    var fileName: String {
        fileURL.lastPathComponent
    }

    var reminders: [Reminder] {
        ReminderTextParser.parse(rawText)
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
    var parent: String?
    var text: String

    var title: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名事项" : trimmed
    }
}

private struct ReminderMetadata: Decodable {
    let createTime: String
    let deadline: String
    let level: Int
    let status: Reminder.Status
    let priority: String?
    let parent: String?

    enum CodingKeys: String, CodingKey {
        case createTime = "CreateTime"
        case deadline = "Deadline"
        case level = "Level"
        case status = "Status"
        case priority = "Priority"
        case parent = "Parent"
    }
}

enum ReminderTextParser {
    static func parse(_ source: String) -> [Reminder] {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var reminders: [Reminder] = []
        var index = 0

        while index + 1 < lines.count {
            let metadataLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let textLine = lines[index + 1]
            index += 2

            guard !metadataLine.isEmpty,
                  let data = metadataLine.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(ReminderMetadata.self, from: data)
            else {
                continue
            }

            reminders.append(
                Reminder(
                    id: "\(metadata.createTime)-\(reminders.count)",
                    createTime: metadata.createTime,
                    deadline: metadata.deadline,
                    level: max(metadata.level, 1),
                    status: metadata.status,
                    priorityID: metadata.priority ?? PriorityDefinition.normal.id,
                    parent: metadata.parent,
                    text: textLine
                )
            )
        }

        return reminders
    }

    static func serialize(_ reminders: [Reminder]) -> String {
        reminders
            .map { reminder in
                "\(metadataLine(for: reminder))\n\(reminder.text)"
            }
            .joined(separator: "\n")
    }

    static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func metadataLine(for reminder: Reminder) -> String {
        var parts = [
            "\"CreateTime\":\"\(jsonEscaped(reminder.createTime))\"",
            "\"Deadline\":\"\(jsonEscaped(reminder.deadline))\"",
            "\"Level\":\(reminder.level)",
            "\"Status\":\"\(reminder.status.rawValue)\"",
            "\"Priority\":\"\(jsonEscaped(reminder.priorityID))\""
        ]

        if let parent = reminder.parent, !parent.isEmpty {
            parts.append("\"Parent\":\"\(jsonEscaped(parent))\"")
        }

        return "{\(parts.joined(separator: ","))}"
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
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

private extension NSColor {
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

struct ContentView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 110, ideal: 260, max: 540)
        } detail: {
            DetailContainerView()
        }
        .onAppear {
            DispatchQueue.main.async {
                workspace.promptForWorkDirectoryIfNeeded()
            }
        }
        .onChange(of: workspace.selectedListID) { _ in
            workspace.persistConfiguration()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    @State private var listEditorMode: ListEditorMode?
    @State private var listPendingDeletion: ReminderListFile?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $workspace.selectedListID) {
                ForEach(workspace.lists) { list in
                    ReminderListRow(list: list)
                        .tag(list.id)
                        .contextMenu {
                            Button {
                                listEditorMode = .rename(list)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                listPendingDeletion = list
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .navigationTitle("列表")

            Divider()

            HStack(spacing: 8) {
                Button {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("打开设置")

                Divider()
                    .frame(height: 16)

                Button {
                    listEditorMode = .create
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建 Reminder 列表")
                .disabled(workspace.workDirectoryURL == nil)

                Button {
                    if let selectedList {
                        listEditorMode = .rename(selectedList)
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .help("重命名当前列表")
                .disabled(selectedList == nil)

                Button(role: .destructive) {
                    listPendingDeletion = selectedList
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除当前列表")
                .disabled(selectedList == nil)

                Spacer()

                Button {
                    workspace.chooseWorkDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .help("修改工作目录")

                Button {
                    workspace.reloadLists()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新读取工作目录")
            }
            .padding(10)
        }
        .frame(minWidth: 250)
        .sheet(item: $listEditorMode) { mode in
            ListNameEditorSheet(mode: mode) { name in
                switch mode {
                case .create:
                    return workspace.createList(named: name)
                case .rename(let list):
                    return workspace.renameList(id: list.id, to: name)
                }
            }
        }
        .alert(
            "删除 Reminder 列表？",
            isPresented: Binding(
                get: { listPendingDeletion != nil },
                set: { if !$0 { listPendingDeletion = nil } }
            ),
            presenting: listPendingDeletion
        ) { list in
            Button("删除", role: .destructive) {
                workspace.deleteList(id: list.id)
                listPendingDeletion = nil
            }

            Button("取消", role: .cancel) {
                listPendingDeletion = nil
            }
        } message: { list in
            Text("“\(list.fileName)” 会被移到废纸篓。")
        }
    }

    private var selectedList: ReminderListFile? {
        guard let selectedListID = workspace.selectedListID else {
            return nil
        }

        return workspace.lists.first { $0.id == selectedListID }
    }
}

enum ListEditorMode: Identifiable {
    case create
    case rename(ReminderListFile)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let list):
            return "rename-\(list.id)"
        }
    }

    var title: String {
        switch self {
        case .create:
            return "新建 Reminder 列表"
        case .rename:
            return "重命名 Reminder 列表"
        }
    }

    var initialName: String {
        switch self {
        case .create:
            return "新建列表"
        case .rename(let list):
            return list.name
        }
    }

    var actionTitle: String {
        switch self {
        case .create:
            return "新建"
        case .rename:
            return "保存"
        }
    }
}

struct ListNameEditorSheet: View {
    let mode: ListEditorMode
    let onSubmit: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(mode: ListEditorMode, onSubmit: @escaping (String) -> Bool) {
        self.mode = mode
        self.onSubmit = onSubmit
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title)
                .font(.title3.weight(.semibold))

            TextField("列表名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            HStack {
                Spacer()

                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode.actionTitle) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    private func submit() {
        if onSubmit(name) {
            dismiss()
        }
    }
}

struct ReminderListRow: View {
    let list: ReminderListFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .lineLimit(1)
                Text("\(list.reminders.count) 个事项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 5)
    }
}

struct DetailContainerView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace

    var body: some View {
        if workspace.workDirectoryURL == nil {
            ChooseWorkDirectoryView()
        } else if let selectedListIndex = workspace.selectedListIndex {
            ReminderListDetail(list: workspace.lists[selectedListIndex])
        } else {
            EmptyDirectoryView()
        }
    }
}

struct ChooseWorkDirectoryView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("选择 Reminder 工作目录")
                .font(.title2.weight(.semibold))
            Text("该目录下的每个 TXT 文件都会显示为一个待办事项列表。")
                .foregroundStyle(.secondary)
            Button {
                workspace.chooseWorkDirectory()
            } label: {
                Label("选择目录", systemImage: "folder")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct EmptyDirectoryView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("工作目录中没有 TXT 列表")
                .font(.title3)
            Text(workspace.workDirectoryDisplayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button {
                workspace.reloadLists()
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ReminderListDetail: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    let list: ReminderListFile
    @State private var searchText = ""
    @State private var ignoresSearchCase = true
    @State private var filtersSearchResults = true
    @State private var isSearchFocused = false
    @State private var searchFocusRequestID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = workspace.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                Divider()
            }

            switch workspace.displayMode {
            case .source:
                TextEditor(
                    text: Binding(
                        get: { currentList.rawText },
                        set: { workspace.updateRawText(for: list.id, rawText: $0) }
                    )
                )
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(16)
                .background(Color(nsColor: .textBackgroundColor))
            case .preview:
                RenderedReminderList(
                    searchText: $searchText,
                    ignoresSearchCase: $ignoresSearchCase,
                    filtersSearchResults: $filtersSearchResults,
                    listID: list.id
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(list.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if workspace.displayMode == .preview {
                    searchField
                }
            }
        }
        .onAppear {
            focusSearchIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reminderFindRequested)) { _ in
            guard workspace.displayMode == .preview,
                  workspace.selectedListID == list.id
            else {
                return
            }

            focusSearchField()
        }
        .onChange(of: workspace.searchRequest?.id) { _ in
            focusSearchIfRequested()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            FocusableSearchField(
                text: $searchText,
                isFocused: $isSearchFocused,
                focusRequestID: searchFocusRequestID
            )
            .frame(width: isSearchFocused || !searchText.isEmpty ? 190 : 130, height: 24)

            if isSearchFocused || !searchText.isEmpty {
                Divider()
                    .frame(height: 16)

                Button {
                    ignoresSearchCase.toggle()
                } label: {
                    Image(systemName: ignoresSearchCase ? "textformat" : "textformat.alt")
                        .foregroundStyle(ignoresSearchCase ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(ignoresSearchCase ? "忽略大小写" : "区分大小写")

                Button {
                    filtersSearchResults.toggle()
                } label: {
                    Image(systemName: filtersSearchResults ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(filtersSearchResults ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(filtersSearchResults ? "仅显示匹配结果" : "显示全部任务并高亮匹配项")
            }
        }
        .frame(width: isSearchFocused || !searchText.isEmpty ? 270 : 150)
        .animation(.easeInOut(duration: 0.15), value: isSearchFocused || !searchText.isEmpty)
    }

    private var currentList: ReminderListFile {
        workspace.lists.first { $0.id == list.id } ?? list
    }

    private func focusSearchIfRequested() {
        guard workspace.searchRequest?.listID == list.id else {
            return
        }

        focusSearchField()
    }

    private func focusSearchField() {
        searchFocusRequestID = UUID()
    }
}

struct FocusableSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequestID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "搜索"
        searchField.delegate = context.coordinator
        searchField.focusRingType = .default
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self

        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        guard let focusRequestID,
              context.coordinator.lastFocusRequestID != focusRequestID
        else {
            return
        }

        context.coordinator.lastFocusRequestID = focusRequestID
        DispatchQueue.main.async { [weak searchField] in
            guard let searchField else {
                return
            }

            searchField.window?.makeFirstResponder(searchField)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: FocusableSearchField
        var lastFocusRequestID: UUID?

        init(parent: FocusableSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }

            parent.text = searchField.stringValue
        }
    }
}

struct RenderedReminderList: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    @State private var focusedReminderID: Reminder.ID?
    @State private var caretRequest: ReminderCaretRequest?
    @State private var pendingHideTokens: [Reminder.ID: UUID] = [:]
    @State private var reminderPendingDeletion: Reminder?
    @State private var selectedReminderIDs: Set<Reminder.ID> = []
    @State private var remindersPendingDeletion: Set<Reminder.ID> = []
    @Binding var searchText: String
    @Binding var ignoresSearchCase: Bool
    @Binding var filtersSearchResults: Bool
    let listID: ReminderListFile.ID

    private var list: ReminderListFile? {
        workspace.lists.first { $0.id == listID }
    }

    private var reminders: [Reminder] {
        list?.reminders ?? []
    }

    private var filteredReminders: [Reminder] {
        reminders.filter {
            (workspace.visibleReminderStatuses.contains($0.status)
                || pendingHideTokens[$0.id] != nil)
                && (!filtersSearchResults || matchesSearch($0))
        }
    }

    var body: some View {
        if reminders.isEmpty {
            EmptyReminderListView(onCreate: createFirstReminder)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredReminders) { reminder in
                            RenderedReminderRow(
                                reminder: reminder,
                                text: textBinding(for: reminder),
                                isFocused: focusedReminderID == reminder.id,
                                caretRequest: caretRequest?.reminderID == reminder.id ? caretRequest : nil,
                                isSelected: selectedReminderIDs.contains(reminder.id),
                                isSelectionMode: !selectedReminderIDs.isEmpty,
                                visibleAttributes: workspace.visibleReminderAttributes,
                                priorityDefinitions: workspace.priorityDefinitions,
                                priority: workspace.priorityDefinition(for: reminder.priorityID),
                                searchText: searchText,
                                ignoresSearchCase: ignoresSearchCase,
                                onReturn: { insertReminder(after: reminder) },
                                onIndent: { indentReminder(reminder) },
                                onOutdent: { outdentReminder(reminder) },
                                onDeleteWhenEmpty: { deleteOrOutdentEmptyReminder(reminder) },
                                onMoveUp: { moveFocus(from: reminder, offset: -1, placement: .lastLine($0)) },
                                onMoveDown: { moveFocus(from: reminder, offset: 1, placement: .firstLine($0)) },
                                onMoveLeft: { moveFocus(from: reminder, offset: -1, placement: .end) },
                                onMoveRight: { moveFocus(from: reminder, offset: 1, placement: .start) },
                                onUndo: { workspace.undoLastChange() },
                                onToggleSelection: { toggleSelection(for: reminder) },
                                onBeginEditing: { selectedReminderIDs.removeAll() },
                                onCopy: { copyTasks(relativeTo: reminder) },
                                onSelectPriority: { setPriority($0, relativeTo: reminder) },
                                onSelectStatus: { setStatus($0, relativeTo: reminder) },
                                onDelete: { requestDeletion(relativeTo: reminder) },
                                onToggleStatus: { toggleStatus(reminder) }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            }
            .onAppear {
                applyFocusRequest()
            }
            .onChange(of: workspace.focusRequest?.id) { _ in
                applyFocusRequest()
            }
            .confirmationDialog(
                deletionDialogTitle,
                isPresented: Binding(
                    get: { !remindersPendingDeletion.isEmpty },
                    set: {
                        if !$0 {
                            reminderPendingDeletion = nil
                            remindersPendingDeletion = []
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if !remindersPendingDeletion.isEmpty {
                    if pendingDeletionHasChildren {
                        Button("删除任务及其子任务", role: .destructive) {
                            softDelete(remindersPendingDeletion, keepingChildren: false)
                        }
                        Button("删除任务，保留子任务") {
                            softDelete(remindersPendingDeletion, keepingChildren: true)
                        }
                    } else {
                        Button("删除任务", role: .destructive) {
                            softDelete(remindersPendingDeletion, keepingChildren: false)
                        }
                    }

                    Button("取消", role: .cancel) {
                        reminderPendingDeletion = nil
                        remindersPendingDeletion = []
                    }
                }
            } message: {
                if pendingDeletionHasChildren {
                    Text("该任务包含子任务。可以一并软删除，或将子任务归并到上一个有效任务。")
                } else {
                    Text("任务会标记为 Deleted，默认在当前列表中隐藏。")
                }
            }
        }
    }

    private func matchesSearch(_ reminder: Reminder) -> Bool {
        guard !searchText.isEmpty else {
            return true
        }

        let options: String.CompareOptions = ignoresSearchCase ? [.caseInsensitive] : []
        return reminder.text.range(of: searchText, options: options) != nil
    }

    private var deletionDialogTitle: String {
        if remindersPendingDeletion.count > 1 {
            return "删除选中的 \(remindersPendingDeletion.count) 个任务？"
        }

        guard let reminder = reminderPendingDeletion else {
            return "删除任务"
        }

        return "删除“\(reminder.title)”？"
    }

    private func applyFocusRequest() {
        guard let request = workspace.focusRequest,
              request.listID == listID
        else {
            return
        }

        focusedReminderID = request.reminderID
        caretRequest = nil
    }

    private func moveFocus(
        from reminder: Reminder,
        offset: Int,
        placement: ReminderCaretPlacement
    ) {
        guard let currentIndex = filteredReminders.firstIndex(where: { $0.id == reminder.id }) else {
            return
        }

        let targetIndex = currentIndex + offset
        guard filteredReminders.indices.contains(targetIndex) else {
            return
        }

        let targetID = filteredReminders[targetIndex].id
        caretRequest = ReminderCaretRequest(reminderID: targetID, placement: placement)
        focusedReminderID = targetID
    }

    private func textBinding(for reminder: Reminder) -> Binding<String> {
        Binding(
            get: {
                reminders.first { $0.id == reminder.id }?.text ?? reminder.text
            },
            set: { newText in
                updateReminder(reminder) { item in
                    item.text = newText
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                }
            }
        )
    }

    private func createFirstReminder() {
        let timestamp = ReminderTextParser.currentTimestamp()
        let reminder = Reminder(
            id: "\(timestamp)-0",
            createTime: timestamp,
            deadline: timestamp,
            level: 1,
            status: .todo,
            priorityID: PriorityDefinition.normal.id,
            parent: nil,
            text: ""
        )

        workspace.updateReminders(for: listID, reminders: [reminder])
        focusedReminderID = reminder.id
    }

    private func updateReminder(_ reminder: Reminder, transform: (inout Reminder) -> Void) {
        var editableReminders = reminders

        guard let index = editableReminders.firstIndex(where: { $0.id == reminder.id }) else {
            return
        }

        transform(&editableReminders[index])
        normalizeParents(in: &editableReminders)
        workspace.updateReminders(for: listID, reminders: editableReminders)
    }

    private func insertReminder(after reminder: Reminder) {
        var editableReminders = reminders

        guard let index = editableReminders.firstIndex(where: { $0.id == reminder.id }) else {
            return
        }

        let timestamp = ReminderTextParser.currentTimestamp()
        let level = editableReminders[index].level
        let newReminder = Reminder(
            id: "\(timestamp)-\(index + 1)",
            createTime: timestamp,
            deadline: timestamp,
            level: level,
            status: .todo,
            priorityID: PriorityDefinition.normal.id,
            parent: parentCreateTime(forLevel: level, before: index + 1, in: editableReminders),
            text: ""
        )

        editableReminders.insert(newReminder, at: index + 1)
        normalizeParents(in: &editableReminders)
        workspace.updateReminders(for: listID, reminders: editableReminders)
        focusedReminderID = newReminder.id
    }

    private func toggleStatus(_ reminder: Reminder) {
        let nextStatus = reminder.status.next

        updateReminder(reminder) { item in
            item.status = nextStatus
        }

        if workspace.visibleReminderStatuses.contains(nextStatus) {
            pendingHideTokens.removeValue(forKey: reminder.id)
            return
        }

        let token = UUID()
        pendingHideTokens[reminder.id] = token

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard pendingHideTokens[reminder.id] == token else {
                return
            }

            pendingHideTokens.removeValue(forKey: reminder.id)
        }
    }

    private func targetIDs(relativeTo reminder: Reminder) -> Set<Reminder.ID> {
        if selectedReminderIDs.contains(reminder.id) {
            return selectedReminderIDs.intersection(Set(reminders.map(\.id)))
        }

        return [reminder.id]
    }

    private func toggleSelection(for reminder: Reminder) {
        if selectedReminderIDs.contains(reminder.id) {
            selectedReminderIDs.remove(reminder.id)
        } else {
            selectedReminderIDs.insert(reminder.id)
        }
    }

    private func copyTasks(relativeTo reminder: Reminder) {
        let targetIDs = targetIDs(relativeTo: reminder)
        let copiedText = reminders
            .filter { targetIDs.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedText, forType: .string)
    }

    private func setPriority(_ priorityID: String, relativeTo reminder: Reminder) {
        let targetIDs = targetIDs(relativeTo: reminder)
        var editableReminders = reminders

        for index in editableReminders.indices where targetIDs.contains(editableReminders[index].id) {
            editableReminders[index].priorityID = priorityID
        }

        workspace.updateReminders(for: listID, reminders: editableReminders)
    }

    private func setStatus(_ status: Reminder.Status, relativeTo reminder: Reminder) {
        let targetIDs = targetIDs(relativeTo: reminder)
        var editableReminders = reminders

        for index in editableReminders.indices where targetIDs.contains(editableReminders[index].id) {
            editableReminders[index].status = status
        }

        workspace.updateReminders(for: listID, reminders: editableReminders)
    }

    private func requestDeletion(relativeTo reminder: Reminder) {
        reminderPendingDeletion = reminder
        remindersPendingDeletion = targetIDs(relativeTo: reminder)
    }

    private var pendingDeletionHasChildren: Bool {
        remindersPendingDeletion.contains { reminderID in
            guard let index = reminders.firstIndex(where: { $0.id == reminderID }),
                  reminders.indices.contains(index + 1)
            else {
                return false
            }

            return reminders[index + 1].level > reminders[index].level
        }
    }

    private func softDelete(_ reminderIDs: Set<Reminder.ID>, keepingChildren: Bool) {
        var editableReminders = reminders

        if keepingChildren {
            let orderedIDs = reminderIDs.sorted { leftID, rightID in
                let left = editableReminders.firstIndex(where: { $0.id == leftID }) ?? -1
                let right = editableReminders.firstIndex(where: { $0.id == rightID }) ?? -1
                return left > right
            }

            for reminderID in orderedIDs {
                guard let index = editableReminders.firstIndex(where: { $0.id == reminderID }) else {
                    continue
                }

                let parentLevel = editableReminders[index].level
                var descendantEnd = index + 1
                while descendantEnd < editableReminders.count,
                      editableReminders[descendantEnd].level > parentLevel {
                    descendantEnd += 1
                }

                editableReminders[index].status = .deleted

                if descendantEnd > index + 1 {
                    let destination = editableReminders[..<index].last {
                        $0.status != .deleted && !reminderIDs.contains($0.id)
                    }
                    let destinationLevel = destination?.level ?? 0
                    let levelOffset = destinationLevel - parentLevel

                    for childIndex in (index + 1)..<descendantEnd {
                        editableReminders[childIndex].level = max(
                            1,
                            editableReminders[childIndex].level + levelOffset
                        )
                    }
                }
            }
        } else {
            var IDsToDelete = reminderIDs

            for reminderID in reminderIDs {
                guard let index = editableReminders.firstIndex(where: { $0.id == reminderID }) else {
                    continue
                }

                let parentLevel = editableReminders[index].level
                var descendantIndex = index + 1
                while descendantIndex < editableReminders.count,
                      editableReminders[descendantIndex].level > parentLevel {
                    IDsToDelete.insert(editableReminders[descendantIndex].id)
                    descendantIndex += 1
                }
            }

            for index in editableReminders.indices where IDsToDelete.contains(editableReminders[index].id) {
                editableReminders[index].status = .deleted
            }
        }

        normalizeParents(in: &editableReminders)
        workspace.updateReminders(for: listID, reminders: editableReminders)
        reminderPendingDeletion = nil
        remindersPendingDeletion = []
        selectedReminderIDs.subtract(reminderIDs)
    }

    private func indentReminder(_ reminder: Reminder) {
        updateReminder(reminder) { item in
            guard let index = reminders.firstIndex(where: { $0.id == reminder.id }),
                  index > 0
            else {
                return
            }

            item.level = reminders[index - 1].level + 1
            item.parent = reminders[index - 1].createTime
        }
    }

    private func outdentReminder(_ reminder: Reminder) {
        updateReminder(reminder) { item in
            item.level = max(item.level - 1, 1)
        }
    }

    private func deleteOrOutdentEmptyReminder(_ reminder: Reminder) {
        var editableReminders = reminders

        guard let index = editableReminders.firstIndex(where: { $0.id == reminder.id }) else {
            return
        }

        if editableReminders[index].level > 1 {
            editableReminders[index].level -= 1
            normalizeParents(in: &editableReminders)
            workspace.updateReminders(for: listID, reminders: editableReminders)
            return
        }

        editableReminders.remove(at: index)
        normalizeParents(in: &editableReminders)
        workspace.updateReminders(for: listID, reminders: editableReminders)
        focusedReminderID = editableReminders.indices.contains(index)
            ? editableReminders[index].id
            : editableReminders.last?.id
    }

    private func normalizeParents(in reminders: inout [Reminder]) {
        for index in reminders.indices {
            let level = reminders[index].level

            if level <= 1 {
                reminders[index].parent = nil
            } else {
                reminders[index].parent = parentCreateTime(
                    forLevel: level,
                    before: index,
                    in: reminders
                )
            }
        }
    }

    private func parentCreateTime(forLevel level: Int, before index: Int, in reminders: [Reminder]) -> String? {
        guard level > 1, index > 0 else {
            return nil
        }

        return reminders[..<index]
            .last { $0.level == level - 1 && $0.status != .deleted }?
            .createTime
    }
}

private enum ReminderEditorMetrics {
    static let font = NSFont.preferredFont(forTextStyle: .body)
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    static let rowHeight = lineHeight
    static let horizontalTextInset: CGFloat = 2
}

enum ReminderCaretPlacement: Equatable {
    case start
    case end
    case firstLine(CGFloat)
    case lastLine(CGFloat)
}

struct ReminderCaretRequest: Equatable {
    let id = UUID()
    let reminderID: Reminder.ID
    let placement: ReminderCaretPlacement
}

struct RenderedReminderRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectionPulse = false

    let reminder: Reminder
    @Binding var text: String
    let isFocused: Bool
    let caretRequest: ReminderCaretRequest?
    let isSelected: Bool
    let isSelectionMode: Bool
    let visibleAttributes: Set<ReminderAttribute>
    let priorityDefinitions: [PriorityDefinition]
    let priority: PriorityDefinition
    let searchText: String
    let ignoresSearchCase: Bool
    let onReturn: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onDeleteWhenEmpty: () -> Void
    let onMoveUp: (CGFloat) -> Void
    let onMoveDown: (CGFloat) -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onUndo: () -> Void
    let onToggleSelection: () -> Void
    let onBeginEditing: () -> Void
    let onCopy: () -> Void
    let onSelectPriority: (String) -> Void
    let onSelectStatus: (Reminder.Status) -> Void
    let onDelete: () -> Void
    let onToggleStatus: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ReminderStatusButton(
                iconName: iconName,
                color: NSColor(hex: priority.colorHex),
                accessibilityLabel: reminder.status.displayName,
                action: onToggleStatus
            )
            .frame(width: 18, height: ReminderEditorMetrics.lineHeight, alignment: .center)
            .opacity(isSelectionMode ? 0.32 : 1)

            ReminderAttributeBadges(
                reminder: reminder,
                visibleAttributes: visibleAttributes,
                priority: priority
            )
            .opacity(isSelectionMode ? 0.32 : 1)

            EditableReminderTextField(
                text: $text,
                isFocused: isFocused,
                caretRequest: caretRequest,
                textColor: textColor,
                textFont: priority.font,
                isSelectionMode: isSelectionMode,
                isStruckThrough: reminder.status == .canceled || reminder.status == .deleted,
                isUnderlined: priority.isUnderlined,
                searchText: searchText,
                ignoresSearchCase: ignoresSearchCase,
                onReturn: onReturn,
                onIndent: onIndent,
                onOutdent: onOutdent,
                onDeleteWhenEmpty: onDeleteWhenEmpty,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onMoveLeft: onMoveLeft,
                onMoveRight: onMoveRight,
                onUndo: onUndo,
                onToggleSelection: onToggleSelection,
                onCancelSelection: onBeginEditing,
                onBeginEditing: onBeginEditing,
                onCopy: onCopy,
                priorityDefinitions: priorityDefinitions,
                selectedPriorityID: reminder.priorityID,
                onSelectPriority: onSelectPriority,
                selectedStatus: reminder.status,
                onSelectStatus: onSelectStatus,
                onDelete: onDelete
            )
            .frame(maxWidth: .infinity, minHeight: ReminderEditorMetrics.lineHeight)
            .opacity(textOpacity)

            Spacer()
        }
        .padding(.leading, CGFloat(reminder.level - 1) * 22)
        .frame(maxWidth: .infinity, minHeight: ReminderEditorMetrics.rowHeight, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.15), value: isSelectionMode)
        .onAppear(perform: updateSelectionPulse)
        .onChange(of: isSelected) { _ in
            updateSelectionPulse()
        }
    }

    private var textOpacity: Double {
        if isSelected {
            return reduceMotion ? 1 : (selectionPulse ? 0.68 : 1)
        }

        return isSelectionMode ? 0.28 : 1
    }

    private func updateSelectionPulse() {
        guard isSelected, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.15)) {
                selectionPulse = false
            }
            return
        }

        selectionPulse = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                selectionPulse = true
            }
        }
    }

    private var iconName: String {
        switch reminder.status {
        case .todo:
            return "circle"
        case .done:
            return "checkmark.circle.fill"
        case .canceled:
            return "minus.circle.fill"
        case .deleted:
            return "trash.circle.fill"
        }
    }

    private var textColor: NSColor {
        NSColor(hex: priority.colorHex)
    }
}

struct ReminderStatusButton: NSViewRepresentable {
    let iconName: String
    let color: NSColor
    let accessibilityLabel: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        button.contentTintColor = color
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

struct ReminderAttributeBadges: View {
    let reminder: Reminder
    let visibleAttributes: Set<ReminderAttribute>
    let priority: PriorityDefinition

    var body: some View {
        HStack(spacing: 4) {
            if visibleAttributes.contains(.time) {
                ReminderAttributeBadge(
                    title: displayTime,
                    systemImage: "calendar"
                )
            }

            if visibleAttributes.contains(.priority) {
                ReminderPriorityBadge(priority: priority)
            }
        }
        .frame(height: ReminderEditorMetrics.lineHeight, alignment: .center)
    }

    private var displayTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        guard let date = formatter.date(from: reminder.deadline) else {
            return reminder.deadline
        }

        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct ReminderPriorityBadge: View {
    let priority: PriorityDefinition

    var body: some View {
        Text(priority.name)
            .font(.caption2)
            .foregroundStyle(priority.color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: ReminderEditorMetrics.lineHeight, alignment: .center)
            .background(priority.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ReminderAttributeBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
        }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 2)
            .frame(height: ReminderEditorMetrics.lineHeight, alignment: .center)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct EditableReminderTextField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let caretRequest: ReminderCaretRequest?
    let textColor: NSColor
    let textFont: NSFont
    let isSelectionMode: Bool
    let isStruckThrough: Bool
    let isUnderlined: Bool
    let searchText: String
    let ignoresSearchCase: Bool
    let onReturn: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onDeleteWhenEmpty: () -> Void
    let onMoveUp: (CGFloat) -> Void
    let onMoveDown: (CGFloat) -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onUndo: () -> Void
    let onToggleSelection: () -> Void
    let onCancelSelection: () -> Void
    let onBeginEditing: () -> Void
    let onCopy: () -> Void
    let priorityDefinitions: [PriorityDefinition]
    let selectedPriorityID: String
    let onSelectPriority: (String) -> Void
    let selectedStatus: Reminder.Status
    let onSelectStatus: (Reminder.Status) -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> ReminderEditingTextView {
        let textView = ReminderEditingTextView()
        textView.delegate = context.coordinator
        textView.font = textFont
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(
            width: ReminderEditorMetrics.horizontalTextInset,
            height: 0
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: ReminderEditorMetrics.lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.onReturn = onReturn
        textView.onIndent = onIndent
        textView.onOutdent = onOutdent
        textView.onDeleteWhenEmpty = onDeleteWhenEmpty
        textView.onMoveUp = onMoveUp
        textView.onMoveDown = onMoveDown
        textView.onMoveLeft = onMoveLeft
        textView.onMoveRight = onMoveRight
        textView.onUndo = onUndo
        textView.onToggleSelection = onToggleSelection
        textView.onCancelSelection = onCancelSelection
        textView.onBeginEditing = onBeginEditing
        textView.onCopy = onCopy
        textView.isSelectionMode = isSelectionMode
        textView.priorityDefinitions = priorityDefinitions
        textView.selectedPriorityID = selectedPriorityID
        textView.onSelectPriority = onSelectPriority
        textView.selectedStatus = selectedStatus
        textView.onSelectStatus = onSelectStatus
        textView.onDelete = onDelete
        textView.setSearchHighlights(query: searchText, ignoresCase: ignoresSearchCase)
        return textView
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ReminderEditingTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }

        return CGSize(width: width, height: nsView.fittingHeight(for: width))
    }

    func updateNSView(_ nsView: ReminderEditingTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }

        nsView.isEditable = true
        nsView.textColor = textColor
        nsView.font = textFont
        nsView.setTextStyle(
            isStruckThrough: isStruckThrough,
            isUnderlined: isUnderlined,
            color: textColor,
            font: textFont
        )
        nsView.setSearchHighlights(query: searchText, ignoresCase: ignoresSearchCase)
        nsView.onReturn = onReturn
        nsView.onIndent = onIndent
        nsView.onOutdent = onOutdent
        nsView.onDeleteWhenEmpty = onDeleteWhenEmpty
        nsView.onMoveUp = onMoveUp
        nsView.onMoveDown = onMoveDown
        nsView.onMoveLeft = onMoveLeft
        nsView.onMoveRight = onMoveRight
        nsView.onUndo = onUndo
        nsView.onToggleSelection = onToggleSelection
        nsView.onCancelSelection = onCancelSelection
        nsView.onBeginEditing = onBeginEditing
        nsView.onCopy = onCopy
        nsView.isSelectionMode = isSelectionMode
        nsView.priorityDefinitions = priorityDefinitions
        nsView.selectedPriorityID = selectedPriorityID
        nsView.onSelectPriority = onSelectPriority
        nsView.selectedStatus = selectedStatus
        nsView.onSelectStatus = onSelectStatus
        nsView.onDelete = onDelete

        nsView.setFocusRequested(isFocused, caretRequest: caretRequest)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let reminderTextView = textView as? ReminderEditingTextView else {
                return false
            }

            return reminderTextView.handleNavigationCommand(commandSelector)
        }
    }
}

final class ReminderEditingTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?
    var onDeleteWhenEmpty: (() -> Void)?
    var onMoveUp: ((CGFloat) -> Void)?
    var onMoveDown: ((CGFloat) -> Void)?
    var onMoveLeft: (() -> Void)?
    var onMoveRight: (() -> Void)?
    var onUndo: (() -> Void)?
    var onToggleSelection: (() -> Void)?
    var onCancelSelection: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onCopy: (() -> Void)?
    var isSelectionMode = false
    var priorityDefinitions: [PriorityDefinition] = PriorityDefinition.defaults
    var selectedPriorityID = PriorityDefinition.normal.id
    var onSelectPriority: ((String) -> Void)?
    var selectedStatus: Reminder.Status = .todo
    var onSelectStatus: ((Reminder.Status) -> Void)?
    var onDelete: (() -> Void)?
    private var wantsFocus = false
    private var isFocusRequestPending = false
    private var caretRequest: ReminderCaretRequest?
    private var appliedCaretRequestID: UUID?

    func setFocusRequested(_ requested: Bool, caretRequest: ReminderCaretRequest?) {
        wantsFocus = requested
        self.caretRequest = caretRequest

        if requested {
            if window?.firstResponder === self {
                applyCaretRequestIfNeeded()
            } else {
                scheduleFocusRequestIfNeeded()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if wantsFocus {
            scheduleFocusRequestIfNeeded()
        }
    }

    private func scheduleFocusRequestIfNeeded() {
        guard !isFocusRequestPending,
              let window,
              window.firstResponder !== self
        else {
            return
        }

        isFocusRequestPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.isFocusRequestPending = false
            guard self.wantsFocus,
                  let window = self.window,
                  window.firstResponder !== self
            else {
                return
            }

            window.makeFirstResponder(self)
            self.applyCaretRequestIfNeeded()
        }
    }

    private func applyCaretRequestIfNeeded() {
        guard let caretRequest,
              caretRequest.id != appliedCaretRequestID
        else {
            return
        }

        appliedCaretRequestID = caretRequest.id
        let textLength = (string as NSString).length
        let location: Int

        switch caretRequest.placement {
        case .start:
            location = 0
        case .end:
            location = textLength
        case let .firstLine(horizontalOffset):
            location = insertionLocation(horizontalOffset: horizontalOffset, useLastLine: false)
        case let .lastLine(horizontalOffset):
            location = insertionLocation(horizontalOffset: horizontalOffset, useLastLine: true)
        }

        setSelectedRange(NSRange(location: min(location, textLength), length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func insertionLocation(horizontalOffset: CGFloat, useLastLine: Bool) -> Int {
        guard let layoutManager,
              let textContainer,
              !string.isEmpty
        else {
            return 0
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let y = useLastLine
            ? max(usedRect.minY, usedRect.maxY - ReminderEditorMetrics.lineHeight / 2)
            : usedRect.minY + ReminderEditorMetrics.lineHeight / 2
        return characterIndexForInsertion(at: NSPoint(x: horizontalOffset, y: y))
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        let textStorage = NSTextStorage(
            string: string,
            attributes: [.font: font ?? ReminderEditorMetrics.font]
        )
        let layoutManager = NSLayoutManager()
        let textWidth = width - ReminderEditorMetrics.horizontalTextInset * 2
        let textContainer = NSTextContainer(
            size: NSSize(width: max(textWidth, 1), height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)

        return max(ReminderEditorMetrics.lineHeight, usedHeight)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyReminderText), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(requestDelete), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)
        menu.addItem(.separator())

        for status in [Reminder.Status.todo, .done, .canceled] {
            let item = NSMenuItem(
                title: status.displayName,
                action: #selector(selectStatus(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = status.rawValue
            item.state = status == selectedStatus ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for priority in priorityDefinitions {
            let item = NSMenuItem(
                title: priority.name,
                action: #selector(selectPriority(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = priority.id
            item.state = priority.id == selectedPriorityID ? .on : .off
            item.image = priorityColorImage(for: priority)
            menu.addItem(item)
        }

        return menu
    }

    @objc private func copyReminderText() {
        onCopy?()
    }

    @objc private func requestDelete() {
        onDelete?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            onToggleSelection?()
            return
        }

        onBeginEditing?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onToggleSelection?()
            return
        }

        super.rightMouseDown(with: event)
    }

    @objc private func selectPriority(_ sender: NSMenuItem) {
        guard let priorityID = sender.representedObject as? String else {
            return
        }

        onSelectPriority?(priorityID)
    }

    @objc private func selectStatus(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let status = Reminder.Status(rawValue: rawValue)
        else {
            return
        }

        onSelectStatus?(status)
    }

    private func priorityColorImage(for priority: PriorityDefinition) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor(hex: priority.colorHex).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        return image
    }

    func setTextStyle(
        isStruckThrough: Bool,
        isUnderlined: Bool,
        color: NSColor,
        font: NSFont
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font,
            .strikethroughStyle: isStruckThrough ? NSUnderlineStyle.single.rawValue : 0,
            .underlineStyle: isUnderlined ? NSUnderlineStyle.single.rawValue : 0
        ]

        guard !string.isEmpty else {
            typingAttributes = attributes
            return
        }

        let range = NSRange(location: 0, length: (string as NSString).length)
        textStorage?.removeAttribute(.backgroundColor, range: range)
        textStorage?.addAttributes(attributes, range: range)
        typingAttributes = attributes
    }

    func setSearchHighlights(query: String, ignoresCase: Bool) {
        guard !query.isEmpty,
              !string.isEmpty,
              let textStorage
        else {
            return
        }

        let text = string as NSString
        let options: NSString.CompareOptions = ignoresCase ? [.caseInsensitive] : []
        var searchRange = NSRange(location: 0, length: text.length)

        while searchRange.length > 0 {
            let matchRange = text.range(of: query, options: options, range: searchRange)
            guard matchRange.location != NSNotFound else {
                return
            }

            textStorage.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.45),
                range: matchRange
            )

            let nextLocation = matchRange.location + matchRange.length
            searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let navigationModifiers = modifiers.subtracting([.numericPad, .function])

        if isSelectionMode, navigationModifiers.isEmpty, event.keyCode == 53 {
            onCancelSelection?()
            return
        }

        if modifiers == .command, event.keyCode == 6 {
            onUndo?()
            return
        }

        if navigationModifiers.isEmpty {
            switch event.keyCode {
            case 115:
                setSelectedRange(NSRange(location: 0, length: 0))
                return
            case 119:
                setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 36, 76:
            onReturn?()
        case 48:
            if event.modifierFlags.contains(.shift) {
                onOutdent?()
            } else {
                onIndent?()
            }
        case 51, 117:
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onDeleteWhenEmpty?()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    func handleNavigationCommand(_ selector: Selector) -> Bool {
        guard selectedRange().length == 0 else {
            return false
        }

        switch NSStringFromSelector(selector) {
        case "moveUp:":
            guard isCaretOnFirstVisualLine else {
                return false
            }
            onMoveUp?(caretHorizontalOffset)
            return true
        case "moveDown:":
            guard isCaretOnLastVisualLine else {
                return false
            }
            onMoveDown?(caretHorizontalOffset)
            return true
        case "moveLeft:", "moveBackward:":
            guard selectedRange().location == 0 else {
                return false
            }
            onMoveLeft?()
            return true
        case "moveRight:", "moveForward:":
            guard selectedRange().location == (string as NSString).length else {
                return false
            }
            onMoveRight?()
            return true
        default:
            return false
        }
    }

    private var isCaretOnFirstVisualLine: Bool {
        guard let lineRange = caretVisualLineGlyphRange else {
            return true
        }

        return lineRange.location == 0
    }

    private var isCaretOnLastVisualLine: Bool {
        guard let layoutManager,
              let lineRange = caretVisualLineGlyphRange
        else {
            return true
        }

        return NSMaxRange(lineRange) == layoutManager.numberOfGlyphs
    }

    private var caretVisualLineGlyphRange: NSRange? {
        guard let layoutManager,
              let textContainer,
              layoutManager.numberOfGlyphs > 0
        else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let textLength = (string as NSString).length
        let characterIndex = min(selectedRange().location, max(0, textLength - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        var lineRange = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
        return lineRange
    }

    private var caretHorizontalOffset: CGFloat {
        var actualRange = NSRange()
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: selectedRange().location, length: 0),
            actualRange: &actualRange
        )
        guard let window else {
            return 0
        }

        let windowPoint = window.convertPoint(fromScreen: screenRect.origin)
        return convert(windowPoint, from: nil).x
    }
}

struct EmptyReminderListView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("这个列表还没有可渲染的事项")
                .font(.title3)
            Button {
                onCreate()
            } label: {
                Label("添加第一项", systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    @State private var priorityPendingDeletion: PriorityDefinition?

    var body: some View {
        Form {
            Section("外观") {
                Picker(
                    "颜色模式",
                    selection: Binding(
                        get: { workspace.colorMode },
                        set: { workspace.setColorMode($0) }
                    )
                ) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("优先级") {
                ForEach(workspace.defaultPriorities) { priority in
                    PriorityEditorRow(priority: priority, isSystem: true) {}
                }

                ForEach(workspace.customPriorities) { priority in
                    PriorityEditorRow(priority: priority, isSystem: false) {
                        priorityPendingDeletion = priority
                    }
                }

                Button {
                    workspace.addCustomPriority()
                } label: {
                    Label("添加优先级", systemImage: "plus")
                }
            }

            Section("工作目录") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.workDirectoryDisplayPath)
                        .font(.callout)
                        .foregroundStyle(workspace.workDirectoryURL == nil ? .secondary : .primary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    HStack {
                        Button {
                            workspace.chooseWorkDirectory()
                        } label: {
                            Label("修改工作目录", systemImage: "folder")
                        }

                        Button {
                            workspace.openWorkDirectoryInFinder()
                        } label: {
                            Label("打开", systemImage: "folder")
                        }
                        .disabled(workspace.workDirectoryURL == nil)

                        Button {
                            workspace.openConfigurationFile()
                        } label: {
                            Label("config.yaml", systemImage: "doc.text")
                        }
                        .disabled(workspace.workDirectoryURL == nil)

                        Button {
                            workspace.reloadLists()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(workspace.workDirectoryURL == nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .alert(
            "删除自定义优先级？",
            isPresented: Binding(
                get: { priorityPendingDeletion != nil },
                set: { if !$0 { priorityPendingDeletion = nil } }
            ),
            presenting: priorityPendingDeletion
        ) { priority in
            Button("删除", role: .destructive) {
                workspace.removeCustomPriority(id: priority.id)
                priorityPendingDeletion = nil
            }

            Button("取消", role: .cancel) {
                priorityPendingDeletion = nil
            }
        } message: { priority in
            Text("“\(priority.name)” 将不再可用于任务。")
        }
    }
}

struct PriorityEditorRow: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    let priority: PriorityDefinition
    let isSystem: Bool
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                CustomPriorityColorPicker(
                    priorityName: priority.name,
                    color: Binding(
                        get: { priority.color },
                        set: { color in
                            workspace.updatePriority(
                                id: priority.id,
                                colorHex: NSColor(color).hexString
                            )
                        }
                    )
                )

                TextField(
                    "",
                    text: Binding(
                        get: { priority.name },
                        set: { name in
                            guard !isSystem else {
                                return
                            }
                            workspace.updatePriority(id: priority.id, name: name)
                        }
                    )
                )
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .frame(width: 118, alignment: .leading)
                .disabled(isSystem)
                .accessibilityLabel("优先级名称")
            }
            .frame(width: 142, alignment: .leading)

            Spacer(minLength: 6)

            Toggle(
                "粗体",
                isOn: Binding(
                    get: { priority.isBold },
                    set: { workspace.updatePriority(id: priority.id, isBold: $0) }
                )
            )
            Toggle(
                "下划线",
                isOn: Binding(
                    get: { priority.isUnderlined },
                    set: { workspace.updatePriority(id: priority.id, isUnderlined: $0) }
                )
            )
            Toggle(
                "斜体",
                isOn: Binding(
                    get: { priority.isItalic },
                    set: { workspace.updatePriority(id: priority.id, isItalic: $0) }
                )
            )

            Spacer(minLength: 0)

            if isSystem {
                Color.clear
                    .frame(width: 16, height: 16)
            } else {
                Button(action: onRequestDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除优先级")
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 3)
    }
}

struct CustomPriorityColorPicker: View {
    private static let presetColors = [
        "#FF3B30", "#FF453A", "#FF6961", "#FF9F0A", "#FFCC00", "#FFD60A",
        "#A2845E", "#AC8E68", "#34C759", "#30D158", "#64D2FF", "#5AC8FA",
        "#0A84FF", "#007AFF", "#5E5CE6", "#5856D6", "#BF5AF2", "#AF52DE",
        "#FF375F", "#FF2D55", "#8E8E93", "#636366", "#48484A", "#3A3A3C",
        "#FFFFFF", "#D1D1D6", "#AEAEB2", "#000000", "#1C1C1E", "#2C2C2E"
    ]

    let priorityName: String
    @Binding var color: Color
    @State private var isShowingPicker = false

    var body: some View {
        Button {
            isShowingPicker = true
        } label: {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help("选择 \(priorityName) 的颜色")
        .accessibilityLabel("选择 \(priorityName) 的颜色")
        .popover(isPresented: $isShowingPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 6),
                    spacing: 6
                ) {
                    ForEach(Self.presetColors, id: \.self) { hex in
                        let presetColor = Color(nsColor: NSColor(hex: hex))

                        Button {
                            color = presetColor
                        } label: {
                            Circle()
                                .fill(presetColor)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Divider()

                ColorPicker("自定义颜色", selection: $color, supportsOpacity: false)
            }
            .padding(12)
        }
    }
}
