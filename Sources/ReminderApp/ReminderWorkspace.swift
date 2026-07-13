import AppKit
import SwiftUI

private struct PendingPomodoroStart {
    let reminder: Reminder
    let listID: ReminderListFile.ID
    let listName: String
    let preset: PomodoroDurationPreset
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
    @Published var customPomodoroPresets: [PomodoroDurationPreset] = []
    @Published var visibleReminderAttributes: Set<ReminderAttribute> = []
    @Published var visibleReminderStatuses: Set<Reminder.Status> = [.todo, .workingOn, .done, .canceled]
    @Published var creationTimeFilter: CreationTimeFilter?
    @Published var showsTaskNumbers = false
    @Published var copiesTaskNumbers = false
    @Published var playsCopySound = true
    @Published var ignoresSearchCase = true
    @Published var filtersSearchResults = true
    @Published var completedTaskFadeDelayMilliseconds = 3_000
    @Published var pomodoroWarningRemainingRatio = 0.20
    @Published var pomodoroWarningRemainingMinutes = 15
    @Published var pomodoroMenuBarWidth = PomodoroMenuBarWidth.defaultValue
    @Published var focusRequest: ReminderFocusRequest?
    @Published var searchRequest: ReminderSearchRequest?
    @Published var errorMessage: String?
    @Published private var pendingPomodoroStart: PendingPomodoroStart?

    @Published private(set) var activeReminderListID: ReminderListFile.ID?
    @Published private(set) var activeReminderID: Reminder.ID?

    let pomodoro = PomodoroController()

    let workDirectoryDefaultsKey = "ReminderWorkDirectoryPath"
    let configurationFileName = "config.yaml"
    private let undoManager = UndoManager()
    private let fileSaveQueue = ReminderSaveQueue()

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    init() {
        pomodoro.onCompleteTask = { [weak self] listID, reminderID in
            self?.completeReminder(listID: listID, reminderID: reminderID)
        }
        pomodoro.onOpenList = { [weak self] listID in
            self?.openListFromPomodoro(listID)
        }
        restoreWorkDirectory()
    }

    private func openListFromPomodoro(_ listID: ReminderListFile.ID) {
        guard lists.contains(where: { $0.id == listID }) else {
            return
        }

        selectedListID = listID
        NSApp.activate(ignoringOtherApps: true)

        let reminderWindow = NSApp.windows.first(where: {
            !($0 is NSPanel) && $0.canBecomeMain && $0.frame.width >= 800
        })
        reminderWindow?.makeKeyAndOrderFront(nil)
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
        guard mode != displayMode else {
            return
        }

        if let selectedListID,
           let index = lists.firstIndex(where: { $0.id == selectedListID }) {
            switch mode {
            case .source:
                lists[index].rawText = ReminderTextParser.serialize(lists[index].reminders)
            case .preview:
                lists[index].reminders = ReminderTextParser.parse(lists[index].rawText)
            }
        }

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

    func setPlaysCopySound(_ enabled: Bool) {
        playsCopySound = enabled
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

    func setCompletedTaskFadeDelayMilliseconds(_ milliseconds: Int) {
        completedTaskFadeDelayMilliseconds = min(max(milliseconds, 0), 5_000)
        persistConfiguration()
    }

    func setPomodoroMenuBarWidth(_ width: CGFloat, persist: Bool = true) {
        pomodoroMenuBarWidth = PomodoroMenuBarWidth.clamped(width.rounded())
        pomodoro.configureMenuBarWidth(pomodoroMenuBarWidth)
        if persist {
            persistConfiguration()
        }
    }

    func setPomodoroWarningRemainingRatio(_ ratio: Double) {
        pomodoroWarningRemainingRatio = min(max(ratio, 0), 1)
        pomodoro.configureWarningThresholds(
            remainingRatio: pomodoroWarningRemainingRatio,
            remainingMinutes: pomodoroWarningRemainingMinutes
        )
        persistConfiguration()
    }

    func setPomodoroWarningRemainingMinutes(_ minutes: Int) {
        pomodoroWarningRemainingMinutes = max(0, minutes)
        pomodoro.configureWarningThresholds(
            remainingRatio: pomodoroWarningRemainingRatio,
            remainingMinutes: pomodoroWarningRemainingMinutes
        )
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

    func setCreationTimeFilter(_ filter: CreationTimeFilter?) {
        creationTimeFilter = filter
        persistConfiguration()
    }

    func matchesCreationTimeFilter(_ reminder: Reminder, now: Date = Date()) -> Bool {
        guard let creationTimeFilter else {
            return true
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        guard let createDate = formatter.date(from: reminder.createTime) else {
            return false
        }

        switch creationTimeFilter {
        case .lastHour:
            return createDate <= now && createDate >= now.addingTimeInterval(-3_600)
        case .today:
            return Calendar.current.isDateInToday(createDate)
        case .lastWeek:
            guard let startDate = Calendar.current.date(byAdding: .day, value: -7, to: now) else {
                return false
            }
            return createDate <= now && createDate >= startDate
        }
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

        let request = PendingPomodoroStart(
            reminder: reminder,
            listID: listID,
            listName: list.name,
            preset: preset
        )

        if pomodoro.hasRunningSession {
            pendingPomodoroStart = request
            return
        }

        startPomodoro(request)
    }

    var isPomodoroStartConfirmationPresented: Bool {
        pendingPomodoroStart != nil
    }

    var isPendingPomodoroRestart: Bool {
        guard let pendingPomodoroStart else {
            return false
        }

        return pomodoro.isActive(
            listID: pendingPomodoroStart.listID,
            reminderID: pendingPomodoroStart.reminder.id
        )
    }

    func confirmPomodoroStart() {
        guard let pendingPomodoroStart else {
            return
        }

        self.pendingPomodoroStart = nil
        startPomodoro(pendingPomodoroStart)
    }

    func cancelPomodoroStart() {
        pendingPomodoroStart = nil
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

    private func startPomodoro(_ request: PendingPomodoroStart) {
        setActiveReminder(listID: request.listID, reminderID: request.reminder.id)
        pomodoro.start(
            listID: request.listID,
            listName: request.listName,
            reminder: request.reminder,
            preset: request.preset
        )
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
            text: "",
            images: []
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

        if displayMode == .source {
            scheduleRawTextSave(at: index)
            flushPendingSave(for: lists[index].fileURL)
            return
        }

        let reminders = lists[index].reminders
        let nonEmptyReminders = reminders.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.images.isEmpty
        }

        if nonEmptyReminders.count != reminders.count {
            objectWillChange.send()
            lists[index].reminders = nonEmptyReminders
        }

        lists[index].rawText = ReminderTextParser.serialize(lists[index].reminders)
        scheduleSave(at: index)
        flushPendingSave(for: lists[index].fileURL)
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
        flushPendingSaves()
        let directoryURL = url.standardizedFileURL
        workDirectoryURL = directoryURL
        UserDefaults.standard.set(directoryURL.path(percentEncoded: false), forKey: workDirectoryDefaultsKey)
        loadConfiguration()
        reloadLists()
        persistConfiguration()
    }

    func reloadLists() {
        flushPendingSaves()
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
        scheduleRawTextSave(at: index)
    }

    func updateReminders(for listID: ReminderListFile.ID, reminders: [Reminder]) {
        guard let index = lists.firstIndex(where: { $0.id == listID }),
              lists[index].reminders != reminders
        else {
            return
        }

        let previousReminders = lists[index].reminders
        undoManager.registerUndo(withTarget: self) { workspace in
            workspace.updateReminders(for: listID, reminders: previousReminders)
        }
        undoManager.setActionName("编辑任务")
        objectWillChange.send()
        lists[index].reminders = reminders
        scheduleSave(at: index)
    }

    func updateReminderText(for listID: ReminderListFile.ID, reminderID: Reminder.ID, text: String) {
        guard let listIndex = lists.firstIndex(where: { $0.id == listID }),
              let reminderIndex = lists[listIndex].reminders.firstIndex(where: { $0.id == reminderID })
        else {
            return
        }

        let previousText = lists[listIndex].reminders[reminderIndex].text
        guard previousText != text else {
            return
        }

        undoManager.registerUndo(withTarget: self) { workspace in
            workspace.updateReminderText(for: listID, reminderID: reminderID, text: previousText)
        }
        undoManager.setActionName("编辑任务")
        lists[listIndex].reminders[reminderIndex].text = text
        scheduleSave(at: listIndex)
    }

    func flushPendingSaves() {
        let errors = fileSaveQueue.flush()
        if let error = errors.values.first {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func flushPendingSave(for url: URL) {
        if let error = fileSaveQueue.flush(url: url) {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func scheduleSave(at index: Int) {
        let fileURL = lists[index].fileURL
        let reminders = lists[index].reminders
        fileSaveQueue.schedule(reminders: reminders, to: fileURL) { [weak self] savedURL, error in
            guard let self else {
                return
            }

            if let error {
                self.errorMessage = "保存 \(savedURL.lastPathComponent) 失败：\(error.localizedDescription)"
            } else if self.errorMessage?.hasPrefix("保存 \(savedURL.lastPathComponent) 失败：") == true {
                self.errorMessage = nil
            }
        }
    }

    private func scheduleRawTextSave(at index: Int) {
        let fileURL = lists[index].fileURL
        let rawText = lists[index].rawText
        fileSaveQueue.schedule(rawText: rawText, to: fileURL) { [weak self] savedURL, error in
            guard let self else {
                return
            }

            if let error {
                self.errorMessage = "保存 \(savedURL.lastPathComponent) 失败：\(error.localizedDescription)"
            } else if self.errorMessage?.hasPrefix("保存 \(savedURL.lastPathComponent) 失败：") == true {
                self.errorMessage = nil
            }
        }
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
        flushPendingSave(for: oldURL)
        let newURL = uniqueTXTFileURL(
            for: requestedName,
            in: oldURL.deletingLastPathComponent(),
            excluding: oldURL
        )

        guard oldURL.path(percentEncoded: false) != newURL.path(percentEncoded: false) else {
            return true
        }

        let oldAssetsURL = assetsDirectoryURL(forListName: lists[index].name)
        let newAssetsURL = assetsDirectoryURL(forListName: newURL.deletingPathExtension().lastPathComponent)
        var didMoveAssets = false

        do {
            if let oldAssetsURL,
               FileManager.default.fileExists(atPath: oldAssetsURL.path(percentEncoded: false)),
               let newAssetsURL {
                guard !FileManager.default.fileExists(atPath: newAssetsURL.path(percentEncoded: false)) else {
                    errorMessage = "重命名列表失败：目标资源目录已存在。"
                    return false
                }

                try FileManager.default.createDirectory(
                    at: newAssetsURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: oldAssetsURL, to: newAssetsURL)
                didMoveAssets = true
            }

            try FileManager.default.moveItem(at: oldURL, to: newURL)
            reloadLists()
            selectedListID = newURL.path(percentEncoded: false)
            return true
        } catch {
            if didMoveAssets,
               let oldAssetsURL,
               let newAssetsURL,
               FileManager.default.fileExists(atPath: newAssetsURL.path(percentEncoded: false)) {
                try? FileManager.default.moveItem(at: newAssetsURL, to: oldAssetsURL)
            }
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
        flushPendingSave(for: fileURL)
        let assetsURL = assetsDirectoryURL(forListName: lists[index].name)

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)

            if let assetsURL,
               FileManager.default.fileExists(atPath: assetsURL.path(percentEncoded: false)) {
                var trashedAssetsURL: NSURL?
                try FileManager.default.trashItem(at: assetsURL, resultingItemURL: &trashedAssetsURL)
            }

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
