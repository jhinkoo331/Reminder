import AppKit
import SwiftUI

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
    @EnvironmentObject private var workspace: ReminderWorkspace
    let list: ReminderListFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .lineLimit(1)
                Text(reminderCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 5)
    }

    private var pendingReminderCount: Int {
        displayedReminders.filter { $0.status == .todo }.count
    }

    private var activeReminderCount: Int {
        displayedReminders.count
    }

    private var displayedReminders: [Reminder] {
        list.reminders.filter { workspace.visibleReminderStatuses.contains($0.status) }
    }

    private var reminderCountLabel: String {
        if workspace.visibleReminderStatuses == [.todo] {
            return "\(pendingReminderCount)个事项"
        }

        return "\(pendingReminderCount)/\(activeReminderCount)个事项"
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

struct SettingsView: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    @State private var priorityPendingDeletion: PriorityDefinition?
    @State private var pomodoroPresetPendingDeletion: PomodoroDurationPreset?

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

            Section("界面") {
                Toggle(
                    "复制时包含任务序号",
                    isOn: Binding(
                        get: { workspace.copiesTaskNumbers },
                        set: { workspace.setCopiesTaskNumbers($0) }
                    )
                )
                .disabled(!workspace.showsTaskNumbers)
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

            Section("番茄时间") {
                ForEach(PomodoroDurationPreset.defaults) { preset in
                    PomodoroPresetEditorRow(preset: preset, isSystem: true) {}
                }

                ForEach(workspace.customPomodoroPresets) { preset in
                    PomodoroPresetEditorRow(preset: preset, isSystem: false) {
                        pomodoroPresetPendingDeletion = preset
                    }
                }

                Button {
                    workspace.addCustomPomodoroPreset()
                } label: {
                    Label("添加时间", systemImage: "plus")
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
        .alert(
            "删除自定义时间？",
            isPresented: Binding(
                get: { pomodoroPresetPendingDeletion != nil },
                set: { if !$0 { pomodoroPresetPendingDeletion = nil } }
            ),
            presenting: pomodoroPresetPendingDeletion
        ) { preset in
            Button("删除", role: .destructive) {
                workspace.removeCustomPomodoroPreset(id: preset.id)
                pomodoroPresetPendingDeletion = nil
            }

            Button("取消", role: .cancel) {
                pomodoroPresetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” 将从任务右键菜单中移除。")
        }
    }
}

struct PomodoroPresetEditorRow: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    let preset: PomodoroDurationPreset
    let isSystem: Bool
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            TextField(
                "名称",
                text: Binding(
                    get: { preset.name },
                    set: { workspace.updateCustomPomodoroPreset(id: preset.id, name: $0) }
                )
            )
            .textFieldStyle(.plain)
            .disabled(isSystem)
            .frame(width: 120)

            Stepper(
                value: Binding(
                    get: { preset.totalMinutes },
                    set: { workspace.updateCustomPomodoroPreset(id: preset.id, seconds: $0 * 60) }
                ),
                in: 1...480,
                step: 5
            ) {
                Text("\(preset.totalMinutes) 分钟")
                    .frame(width: 76, alignment: .leading)
            }
            .disabled(isSystem)

            Spacer()

            if isSystem {
                Text("默认")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: onRequestDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除时间")
            }
        }
        .padding(.vertical, 3)
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
