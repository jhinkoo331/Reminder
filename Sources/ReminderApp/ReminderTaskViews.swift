import AppKit
import SwiftUI

struct ReminderListDetail: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    let list: ReminderListFile
    @State private var searchText = ""
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
                    isSearchFocused: $isSearchFocused,
                    ignoresSearchCase: Binding(
                        get: { workspace.ignoresSearchCase },
                        set: { workspace.setIgnoresSearchCase($0) }
                    ),
                    filtersSearchResults: Binding(
                        get: { workspace.filtersSearchResults },
                        set: { workspace.setFiltersSearchResults($0) }
                    ),
                    listID: list.id,
                    pomodoro: workspace.pomodoro
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
        let isExpanded = isSearchFocused || !searchText.isEmpty

        return HStack(spacing: 6) {
            FocusableSearchField(
                text: $searchText,
                isFocused: $isSearchFocused,
                focusRequestID: searchFocusRequestID
            )
            .frame(width: isExpanded ? 190 : 130, height: 24)

            HStack(spacing: 6) {
                Divider()
                    .frame(height: 16)

                Button {
                    workspace.setIgnoresSearchCase(!workspace.ignoresSearchCase)
                } label: {
                    Image(systemName: workspace.ignoresSearchCase ? "textformat.alt" : "textformat")
                        .foregroundStyle(workspace.ignoresSearchCase ? .secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help(
                    workspace.ignoresSearchCase
                        ? "忽略大小写：搜索不区分大小写。点击后改为匹配大小写。"
                        : "匹配大小写：搜索会区分大小写。点击后改为忽略大小写。"
                )

                Button {
                    workspace.setFiltersSearchResults(!workspace.filtersSearchResults)
                } label: {
                    Image(systemName: workspace.filtersSearchResults ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(workspace.filtersSearchResults ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(
                    workspace.filtersSearchResults
                        ? "仅显示匹配任务：隐藏不匹配的任务。点击后显示全部任务并高亮匹配内容。"
                        : "显示全部任务：高亮匹配内容。点击后仅显示匹配任务。"
                )
            }
            .frame(width: isExpanded ? 66 : 0, alignment: .leading)
            .opacity(isExpanded ? 1 : 0)
            .scaleEffect(x: isExpanded ? 1 : 0.82, y: 1, anchor: .leading)
            .allowsHitTesting(isExpanded)
            .clipped()
        }
        .frame(width: isExpanded ? 270 : 150, alignment: .leading)
        .animation(
            .interpolatingSpring(stiffness: 300, damping: 30),
            value: isExpanded
        )
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
        let searchField = FocusTrackingSearchField()
        searchField.placeholderString = "搜索"
        searchField.delegate = context.coordinator
        searchField.focusRingType = .default
        searchField.onFocusChanged = { [weak coordinator = context.coordinator] isFocused in
            coordinator?.setFocus(isFocused)
        }
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
            setFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            setFocus(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }

            parent.text = searchField.stringValue
        }

        func setFocus(_ isFocused: Bool) {
            guard parent.isFocused != isFocused else {
                return
            }

            parent.isFocused = isFocused
        }
    }
}

private final class FocusTrackingSearchField: NSSearchField {
    var onFocusChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocusChanged?(true)
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocusChanged?(true)
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFocusChanged?(false)
        }
        return didResignFirstResponder
    }
}

struct RenderedReminderList: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    private let pomodoro: PomodoroController
    @State private var focusedReminderID: Reminder.ID?
    @State private var caretRequest: ReminderCaretRequest?
    @State private var pendingHideTokens: [Reminder.ID: UUID] = [:]
    @State private var reminderPendingDeletion: Reminder?
    @State private var selectedReminderIDs: Set<Reminder.ID> = []
    @State private var remindersPendingDeletion: Set<Reminder.ID> = []
    @State private var activePomodoroReminderID: Reminder.ID?
    @Binding var searchText: String
    @Binding var isSearchFocused: Bool
    @Binding var ignoresSearchCase: Bool
    @Binding var filtersSearchResults: Bool
    let listID: ReminderListFile.ID

    init(
        searchText: Binding<String>,
        isSearchFocused: Binding<Bool>,
        ignoresSearchCase: Binding<Bool>,
        filtersSearchResults: Binding<Bool>,
        listID: ReminderListFile.ID,
        pomodoro: PomodoroController
    ) {
        _searchText = searchText
        _isSearchFocused = isSearchFocused
        _ignoresSearchCase = ignoresSearchCase
        _filtersSearchResults = filtersSearchResults
        self.listID = listID
        self.pomodoro = pomodoro
    }

    private var list: ReminderListFile? {
        workspace.lists.first { $0.id == listID }
    }

    private var reminders: [Reminder] {
        list?.reminders ?? []
    }

    private var filteredReminders: [Reminder] {
        let matchingReminders = reminders.filter {
            (workspace.visibleReminderStatuses.contains($0.status)
                || pendingHideTokens[$0.id] != nil)
                && workspace.matchesCreationTimeFilter($0)
                && (!filtersSearchResults || matchesSearch($0))
        }

        guard workspace.creationTimeFilter != nil else {
            return matchingReminders
        }

        var visibleReminderIDs = Set(matchingReminders.map(\.id))
        var ancestors: [Reminder] = []

        for reminder in reminders {
            while let ancestor = ancestors.last, ancestor.level >= reminder.level {
                ancestors.removeLast()
            }

            if visibleReminderIDs.contains(reminder.id) {
                visibleReminderIDs.formUnion(ancestors.map(\.id))
            }
            ancestors.append(reminder)
        }

        return reminders.filter { visibleReminderIDs.contains($0.id) }
    }

    private var taskNumbers: [Reminder.ID: String] {
        makeTaskNumbers(for: filteredReminders)
    }

    private func makeTaskNumbers(for visibleReminders: [Reminder]) -> [Reminder.ID: String] {
        var counters: [Int] = []
        var numbers: [Reminder.ID: String] = [:]

        for reminder in visibleReminders {
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

    var body: some View {
        if reminders.isEmpty {
            EmptyReminderListView(onCreate: createFirstReminder)
        } else {
            VStack(spacing: 0) {
                PomodoroPinnedTaskSection(pomodoro: pomodoro, listID: listID)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredReminders) { reminder in
                            RenderedReminderRow(
                                reminder: reminder,
                                text: textBinding(for: reminder),
                                isFocused: !isSearchFocused && focusedReminderID == reminder.id,
                                caretRequest: caretRequest?.reminderID == reminder.id ? caretRequest : nil,
                                isSelected: selectedReminderIDs.contains(reminder.id),
                                isSelectionMode: !selectedReminderIDs.isEmpty,
                                isPomodoroActive: activePomodoroReminderID == reminder.id,
                                taskNumber: workspace.showsTaskNumbers ? taskNumbers[reminder.id] : nil,
                                assetsDirectoryURL: workspace.assetsDirectoryURL(for: listID),
                                visibleAttributes: workspace.visibleReminderAttributes,
                                priorityDefinitions: workspace.priorityDefinitions,
                                priority: workspace.priorityDefinition(for: reminder.priorityID),
                                searchText: searchText,
                                ignoresSearchCase: ignoresSearchCase,
                                onReturn: { isAtLineStart in
                                    if isAtLineStart {
                                        insertReminder(before: reminder)
                                    } else {
                                        insertReminder(after: reminder)
                                    }
                                },
                                onIndent: { indentReminder(reminder) },
                                onOutdent: { outdentReminder(reminder) },
                                onDeleteWhenEmpty: { deleteOrOutdentEmptyReminder(reminder) },
                                onMoveUp: { moveFocus(from: reminder, offset: -1, placement: .lastLine($0)) },
                                onMoveDown: { moveFocus(from: reminder, offset: 1, placement: .firstLine($0)) },
                                onMoveLeft: { moveFocus(from: reminder, offset: -1, placement: .end) },
                                onMoveRight: { moveFocus(from: reminder, offset: 1, placement: .start) },
                                onUndo: { workspace.undoLastChange() },
                                onToggleSelection: {
                                    workspace.setActiveReminder(listID: listID, reminderID: reminder.id)
                                    toggleSelection(for: reminder)
                                },
                                onBeginEditing: {
                                    focusedReminderID = reminder.id
                                    caretRequest = nil
                                    workspace.setActiveReminder(listID: listID, reminderID: reminder.id)
                                    selectedReminderIDs.removeAll()
                                },
                                onPasteImage: { image in
                                    workspace.insertClipboardImage(image, into: reminder.id, in: listID)
                                },
                                playsCopySound: workspace.playsCopySound,
                                onCopy: { copyTasks(relativeTo: reminder) },
                                onSelectPriority: { setPriority($0, relativeTo: reminder) },
                                onSelectStatus: { setStatus($0, relativeTo: reminder) },
                                pomodoroPresets: workspace.pomodoroPresets,
                                onStartPomodoro: { workspace.startPomodoro(for: reminder, in: listID, presetID: $0) },
                                onRemoveImage: { image in
                                    workspace.removeImage(image, from: reminder.id, in: listID)
                                },
                                onSetImageScale: { image, scale in
                                    workspace.setImageScale(scale, for: image, in: reminder.id, listID: listID)
                                },
                                onDelete: { requestDeletion(relativeTo: reminder) },
                                onToggleStatus: { toggleStatus(reminder) }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.22), value: filteredReminders.map(\.id))
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
            .onChange(of: isSearchFocused) { focused in
                if focused {
                    focusedReminderID = nil
                    caretRequest = nil
                }
            }
            .onReceive(pomodoro.$activeSession) { session in
                activePomodoroReminderID = session?.listID == listID ? session?.reminderID : nil
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
        workspace.setActiveReminder(listID: listID, reminderID: request.reminderID)
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
                workspace.updateReminderText(
                    for: listID,
                    reminderID: reminder.id,
                    text: newText
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                )
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
            text: "",
            images: []
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
            text: "",
            images: []
        )

        editableReminders.insert(newReminder, at: index + 1)
        workspace.updateReminders(for: listID, reminders: editableReminders)
        focusedReminderID = newReminder.id
    }

    private func insertReminder(before reminder: Reminder) {
        var editableReminders = reminders

        guard let index = editableReminders.firstIndex(where: { $0.id == reminder.id }) else {
            return
        }

        let timestamp = ReminderTextParser.currentTimestamp()
        let level = editableReminders[index].level
        let newReminder = Reminder(
            id: "\(timestamp)-\(index)",
            createTime: timestamp,
            deadline: timestamp,
            level: level,
            status: .todo,
            priorityID: PriorityDefinition.normal.id,
            text: "",
            images: []
        )

        editableReminders.insert(newReminder, at: index)
        workspace.updateReminders(for: listID, reminders: editableReminders)
        focusedReminderID = newReminder.id
    }

    private func toggleStatus(_ reminder: Reminder) {
        let nextStatus = reminder.status.next
        let shouldDelayHiding = !workspace.visibleReminderStatuses.contains(nextStatus)
        let hideToken = shouldDelayHiding ? UUID() : nil

        if let hideToken {
            pendingHideTokens[reminder.id] = hideToken
        } else {
            pendingHideTokens.removeValue(forKey: reminder.id)
        }

        var statusTransaction = Transaction(animation: nil)
        statusTransaction.disablesAnimations = true
        withTransaction(statusTransaction) {
            updateReminder(reminder) { item in
                item.status = nextStatus
            }
        }

        guard let hideToken else {
            return
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(workspace.completedTaskFadeDelayMilliseconds)
        ) {
            guard pendingHideTokens[reminder.id] == hideToken else {
                return
            }

            _ = withAnimation(.easeInOut(duration: 0.22)) {
                pendingHideTokens.removeValue(forKey: reminder.id)
            }
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
        let copyTaskNumbers = makeTaskNumbers(for: filteredReminders)
        let copiedText = reminders
            .filter { targetIDs.contains($0.id) }
            .map { reminder in
                guard workspace.showsTaskNumbers,
                      workspace.copiesTaskNumbers,
                      let taskNumber = copyTaskNumbers[reminder.id]
                else {
                    return reminder.text
                }

                return "\(taskNumber) \(reminder.text)"
            }
            .joined(separator: "\n")

        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(copiedText, forType: .string),
           workspace.playsCopySound {
            ReminderCopySound.play()
        }
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

        guard editableReminders[index].images.isEmpty else {
            return
        }

        if editableReminders[index].level > 1 {
            editableReminders[index].level -= 1
            workspace.updateReminders(for: listID, reminders: editableReminders)
            return
        }

        editableReminders.remove(at: index)
        workspace.updateReminders(for: listID, reminders: editableReminders)
        focusedReminderID = editableReminders.indices.contains(index)
            ? editableReminders[index].id
            : editableReminders.last?.id
    }

}

private struct PomodoroPinnedTaskSection: View {
    @ObservedObject var pomodoro: PomodoroController
    let listID: ReminderListFile.ID

    var body: some View {
        if let session = pomodoro.activeSession, session.listID == listID {
            PomodoroPinnedTaskCard(
                session: session,
                remainingSeconds: pomodoro.remainingSeconds,
                onCancel: { pomodoro.cancel() }
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()
        }
    }
}

struct PomodoroPinnedTaskCard: View {
    let session: PomodoroSession
    let remainingSeconds: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: ReminderEditorMetrics.lineHeight, alignment: .center)

            VStack(alignment: .leading, spacing: 5) {
                Text(session.taskText)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .frame(maxWidth: .infinity)
            }

            Text("\(elapsedMinutes)/\(session.durationSeconds.pomodoroDisplayMinutes)min")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("取消倒计时")
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var progress: Double {
        guard session.durationSeconds > 0 else {
            return 0
        }

        return 1 - Double(remainingSeconds) / Double(session.durationSeconds)
    }

    private var elapsedMinutes: Int {
        max(0, session.durationSeconds - remainingSeconds) / 60
    }
}

private extension Int {
    var pomodoroDisplayMinutes: Int {
        Swift.max(0, Int(ceil(Double(self) / 60)))
    }
}

enum ReminderEditorMetrics {
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
    let isPomodoroActive: Bool
    let taskNumber: String?
    let assetsDirectoryURL: URL?
    let visibleAttributes: Set<ReminderAttribute>
    let priorityDefinitions: [PriorityDefinition]
    let priority: PriorityDefinition
    let searchText: String
    let ignoresSearchCase: Bool
    let onReturn: (Bool) -> Void
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
    let onPasteImage: (ReminderClipboardImage) -> Void
    let playsCopySound: Bool
    let onCopy: () -> Void
    let onSelectPriority: (String) -> Void
    let onSelectStatus: (Reminder.Status) -> Void
    let pomodoroPresets: [PomodoroDurationPreset]
    let onStartPomodoro: (String) -> Void
    let onRemoveImage: (ReminderImageAttachment) -> Void
    let onSetImageScale: (ReminderImageAttachment, Int) -> Void
    let onDelete: () -> Void
    let onToggleStatus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
            ReminderStatusButton(
                iconName: iconName,
                color: statusColor,
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

            HStack(alignment: .top, spacing: 4) {
                if let taskNumber {
                    Text(taskNumber)
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.82))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.top, 2)
                        .accessibilityLabel("任务序号 \(taskNumber)")
                }

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
                    onPasteImage: onPasteImage,
                    playsCopySound: playsCopySound,
                    onCopy: onCopy,
                    priorityDefinitions: priorityDefinitions,
                    selectedPriorityID: reminder.priorityID,
                    onSelectPriority: onSelectPriority,
                    selectedStatus: reminder.status,
                    onSelectStatus: onSelectStatus,
                    pomodoroPresets: pomodoroPresets,
                    onStartPomodoro: onStartPomodoro,
                    onDelete: onDelete
                )
            }
            .frame(maxWidth: .infinity, minHeight: ReminderEditorMetrics.lineHeight)
            .opacity(textOpacity)

            Spacer()
            }

            if !reminder.images.isEmpty {
                ReminderImageAttachmentsView(
                    attachments: reminder.images,
                    assetsDirectoryURL: assetsDirectoryURL,
                    onRemove: onRemoveImage,
                    onSetScale: onSetImageScale
                )
                .padding(.leading, 26)
            }
        }
        .padding(.leading, CGFloat(reminder.level - 1) * 22)
        .padding(.horizontal, isPomodoroActive ? 8 : 0)
        .padding(.vertical, isPomodoroActive ? 5 : 0)
        .frame(maxWidth: .infinity, minHeight: ReminderEditorMetrics.rowHeight, alignment: .topLeading)
        .background(
            isPomodoroActive ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
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
        case .workingOn:
            return "circle.inset.filled"
        case .done:
            return "checkmark.circle.fill"
        case .canceled:
            return "minus.circle.fill"
        case .deleted:
            return "trash.circle.fill"
        }
    }

    private var statusColor: NSColor {
        reminder.status == .workingOn
            ? .systemBlue
            : NSColor(hex: priority.colorHex)
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
        button.imageScaling = .scaleNone
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
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
