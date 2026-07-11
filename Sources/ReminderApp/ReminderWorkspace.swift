import AppKit
import SwiftUI

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
    @Published var customPomodoroPresets: [PomodoroDurationPreset] = []
    @Published var visibleReminderAttributes: Set<ReminderAttribute> = []
    @Published var visibleReminderStatuses: Set<Reminder.Status> = [.todo, .done, .canceled]
    @Published var showsTaskNumbers = false
    @Published var copiesTaskNumbers = false
    @Published var ignoresSearchCase = true
    @Published var filtersSearchResults = true
    @Published var pomodoroWarningRemainingRatio = 0.20
    @Published var pomodoroWarningRemainingMinutes = 10
    @Published var focusRequest: ReminderFocusRequest?
    @Published var searchRequest: ReminderSearchRequest?
    @Published var errorMessage: String?

    @Published private(set) var activeReminderListID: ReminderListFile.ID?
    @Published private(set) var activeReminderID: Reminder.ID?

    let pomodoro = PomodoroController()

    let workDirectoryDefaultsKey = "ReminderWorkDirectoryPath"
    let configurationFileName = "config.yaml"
    private let undoManager = UndoManager()

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    init() {
        pomodoro.onCompleteTask = { [weak self] listID, reminderID in
            self?.completeReminder(listID: listID, reminderID: reminderID)
        }
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

    func setShowsTaskNumbers(_ enabled: Bool) {
        showsTaskNumbers = enabled
        if !enabled {
            copiesTaskNumbers = false
        }
        persistConfiguration()
    }

    func setCopiesTaskNumbers(_ enabled: Bool) {
        copiesTaskNumbers = enabled
        persistConfiguration()
    }

    func setIgnoresSearchCase(_ enabled: Bool) {
        ignoresSearchCase = enabled
        persistConfiguration()
    }

    func setFiltersSearchResults(_ enabled: Bool) {
        filtersSearchResults = enabled
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

    var pomodoroPresets: [PomodoroDurationPreset] {
        PomodoroDurationPreset.defaults + customPomodoroPresets
    }

    func addCustomPomodoroPreset() {
        customPomodoroPresets.append(
            PomodoroDurationPreset(
                id: "custom-duration-\(UUID().uuidString)",
                name: "45分钟",
                seconds: 45 * 60
            )
        )
        persistConfiguration()
    }

    func updateCustomPomodoroPreset(id: String, name: String? = nil, seconds: Int? = nil) {
        guard let index = customPomodoroPresets.firstIndex(where: { $0.id == id }) else {
            return
        }

        if let name {
            let cleanedName = name
                .replacingOccurrences(of: "|", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            customPomodoroPresets[index].name = cleanedName.isEmpty ? "自定义时间" : cleanedName
        }
        if let seconds {
            customPomodoroPresets[index].seconds = max(seconds, 60)
        }
        persistConfiguration()
    }

    func removeCustomPomodoroPreset(id: String) {
        customPomodoroPresets.removeAll { $0.id == id }
        persistConfiguration()
    }

    func startPomodoro(for reminder: Reminder, in listID: ReminderListFile.ID, presetID: String) {
        guard let preset = pomodoroPresets.first(where: { $0.id == presetID }) else {
            return
        }

        guard let list = lists.first(where: { $0.id == listID }) else {
            return
        }

        setActiveReminder(listID: listID, reminderID: reminder.id)
        pomodoro.start(listID: listID, listName: list.name, reminder: reminder, preset: preset)
    }

    func setActiveReminder(listID: ReminderListFile.ID, reminderID: Reminder.ID) {
        activeReminderListID = listID
        activeReminderID = reminderID
    }

    var canStartPomodoroForActiveReminder: Bool {
        activeReminder != nil
    }

    func startPomodoroForActiveReminder(presetID: String) {
        guard let activeReminder,
              let listID = activeReminderListID
        else {
            return
        }

        startPomodoro(for: activeReminder, in: listID, presetID: presetID)
    }

    private var activeReminder: Reminder? {
        guard let activeReminderListID,
              let activeReminderID
        else {
            return nil
        }

        return lists
            .first(where: { $0.id == activeReminderListID })?
            .reminders
            .first(where: { $0.id == activeReminderID })
    }

    private func completeReminder(listID: ReminderListFile.ID, reminderID: Reminder.ID) {
        guard let list = lists.first(where: { $0.id == listID }) else {
            return
        }

        var reminders = list.reminders
        guard let index = reminders.firstIndex(where: { $0.id == reminderID }) else {
            return
        }

        reminders[index].status = .done
        updateReminders(for: listID, reminders: reminders)
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
}
