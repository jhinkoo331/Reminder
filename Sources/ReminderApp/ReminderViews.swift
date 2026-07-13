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

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case action
    case priority
    case pomodoro

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .action: "switch.2"
        case .priority: "flag"
        case .pomodoro: "timer"
        }
    }

    func title(isChinese: Bool) -> String {
        switch self {
        case .general: isChinese ? "通用" : "General"
        case .action: isChinese ? "行为" : "Action"
        case .priority: isChinese ? "任务优先级" : "Priority"
        case .pomodoro: isChinese ? "番茄任务" : "Pomodoro Task"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPane: SettingsPane = .general
    @State private var language = "中文"
    @State private var colorMode = "system"
    @State private var showsTaskNumbers = true
    @State private var playsCopySound = true
    @State private var copiesTaskNumbers = true
    @State private var completedTaskHideDelay = 300
    @State private var customPriorities = ["自定义优先级"]
    @State private var customDurations = [30]
    @State private var priorityPendingDeletion: Int?
    @State private var durationPendingDeletion: Int?

    private var isChinese: Bool { language == "中文" }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title(isChinese: isChinese), systemImage: pane.systemImage)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 192)
        } detail: {
            Form {
                if selectedPane == .general {
                    Section(isChinese ? "通用" : "General") {
                LabeledContent("语言/Language") {
                    Picker("", selection: $language) {
                        Text("中文").tag("中文")
                        Text("English").tag("English")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                Picker(isChinese ? "颜色模式" : "Color Mode", selection: $colorMode) {
                    Text(isChinese ? "浅色" : "Light").tag("light")
                    Text(isChinese ? "深色" : "Dark").tag("dark")
                    Text(isChinese ? "跟随系统" : "System").tag("system")
                }
                .pickerStyle(.segmented)

            Section("界面") {
                Toggle(
                    "复制时播放音效",
                    isOn: Binding(
                        get: { workspace.playsCopySound },
                        set: { workspace.setPlaysCopySound($0) }
                    )
                )

                Toggle(
                    "复制时包含任务序号",
                    isOn: Binding(
                        get: { workspace.copiesTaskNumbers },
                        set: { workspace.setCopiesTaskNumbers($0) }
                    )
                )
                .disabled(!workspace.showsTaskNumbers)

HStack {
    Text("完成任务隐藏延迟")
    
    Spacer()
    
    TextField(
        "", // 占位符为空，不再显示“毫秒”
        value: Binding(
            get: { workspace.completedTaskFadeDelayMilliseconds },
            set: { workspace.setCompletedTaskFadeDelayMilliseconds($0) }
        ),
        format: .number
    )
    .textFieldStyle(.roundedBorder)
    .frame(width: 64)
    
    Text("ms") // 改为“ms”，并且使用默认字体颜色
}
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("菜单栏宽度")
                        Spacer()
                        Text("\(Int(workspace.pomodoroMenuBarWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { workspace.pomodoroMenuBarWidth },
                            set: { workspace.setPomodoroMenuBarWidth($0, persist: false) }
                        ),
                        in: PomodoroMenuBarWidth.minimum...PomodoroMenuBarWidth.maximum,
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                workspace.setPomodoroMenuBarWidth(workspace.pomodoroMenuBarWidth)
                            }
                        }
                    )
                    .frame(width: 400)
                }

                HStack {
                    Text("标红剩余比例")
                    Spacer()

                    TextField(
                        "",
                        value: Binding(
                            get: { workspace.pomodoroWarningRemainingRatio * 100 },
                            set: { workspace.setPomodoroWarningRemainingRatio($0 / 100) }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                    Text("%")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("标红剩余时间")
                    Spacer()

                    TextField(
                        "",
                        value: Binding(
                            get: { workspace.pomodoroWarningRemainingMinutes },
                            set: { workspace.setPomodoroWarningRemainingMinutes($0) }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                    Text("分钟")
                        .foregroundStyle(.secondary)
                }

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
                }
                HStack(spacing: 12) {
                    SettingsActionButton(
                        isChinese ? "选择工作目录" : "Select",
                        systemImage: "folder.badge.plus"
                    )
                    SettingsActionButton(
                        isChinese ? "打开目录" : "Open",
                        systemImage: "folder"
                    )
                    SettingsActionButton("config.yaml", systemImage: "doc.text")
                    SettingsActionButton(
                        isChinese ? "刷新" : "Refresh",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                    }
                }

                if selectedPane == .action {
                    Section(isChinese ? "行为" : "Action") {
                Toggle(isChinese ? "显示任务序号" : "Show Task Numbers", isOn: $showsTaskNumbers)
                Toggle(
                    isChinese ? "复制时包含任务序号" : "Include Task Numbers When Copying",
                    isOn: $copiesTaskNumbers
                )
                    .padding(.leading, 22)
                    .disabled(!showsTaskNumbers)
                Toggle(isChinese ? "复制时播放音效" : "Play Sound When Copying", isOn: $playsCopySound)
                LabeledContent(isChinese ? "完成任务隐藏延迟" : "Completed Task Hide Delay") {
                    HStack(spacing: 6) {
                        TextField("", value: $completedTaskHideDelay, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        Text(language == "中文" ? "毫秒" : "ms")
                    }
                }
                    }
                }

                if selectedPane == .priority {
                    Section(isChinese ? "任务优先级" : "Priority") {
                SettingsPriorityPreviewRow(
                    name: isChinese ? "高优先级" : "High",
                    color: .red,
                    isBuiltIn: true,
                    isChinese: isChinese
                )
                SettingsPriorityPreviewRow(
                    name: isChinese ? "中优先级" : "Medium",
                    color: .orange,
                    isBuiltIn: true,
                    isChinese: isChinese
                )
                SettingsPriorityPreviewRow(
                    name: isChinese ? "低优先级" : "Low",
                    color: .blue,
                    isBuiltIn: true,
                    isChinese: isChinese
                )
                ForEach(customPriorities.indices, id: \.self) { index in
                    SettingsPriorityPreviewRow(
                        name: customPriorities[index],
                        color: .green,
                        isBuiltIn: false,
                        isChinese: isChinese,
                        onNameChange: { customPriorities[index] = $0 },
                        onDelete: { priorityPendingDeletion = index }
                    )
                }
                Button {
                    customPriorities.append(isChinese ? "自定义优先级" : "Custom Priority")
                } label: {
                    Label(isChinese ? "添加优先级" : "Add Priority", systemImage: "plus")
                }
                    }
                }

                if selectedPane == .pomodoro {
                    Section(isChinese ? "番茄任务" : "Pomodoro Task") {
                SettingsPomodoroPreviewRow(
                    totalMinutes: 25,
                    isBuiltIn: true,
                    isChinese: isChinese
                )
                SettingsPomodoroPreviewRow(
                    totalMinutes: 30,
                    isBuiltIn: true,
                    isChinese: isChinese
                )
                ForEach(customDurations.indices, id: \.self) { index in
                    SettingsPomodoroPreviewRow(
                        totalMinutes: customDurations[index],
                        isBuiltIn: false,
                        isChinese: isChinese,
                        onDelete: { durationPendingDeletion = index }
                    )
                }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
            .navigationTitle(selectedPane.title(isChinese: isChinese))
            .frame(minWidth: 544, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar(.hidden, for: .windowToolbar)
        .background(SettingsWindowTitle(title: isChinese ? "设置" : "Settings"))
        .onExitCommand { dismiss() }
        .alert(
            isChinese ? "删除自定义优先级？" : "Delete Custom Priority?",
            isPresented: Binding(
                get: { priorityPendingDeletion != nil },
                set: { if !$0 { priorityPendingDeletion = nil } }
            )
        ) {
            Button(isChinese ? "取消" : "Cancel", role: .cancel) {}
            Button(isChinese ? "删除" : "Delete", role: .destructive) {
                if let index = priorityPendingDeletion, customPriorities.indices.contains(index) {
                    customPriorities.remove(at: index)
                }
                priorityPendingDeletion = nil
            }
        }
        .alert(
            isChinese ? "删除自定义时长？" : "Delete Custom Duration?",
            isPresented: Binding(
                get: { durationPendingDeletion != nil },
                set: { if !$0 { durationPendingDeletion = nil } }
            )
        ) {
            Button(isChinese ? "取消" : "Cancel", role: .cancel) {}
            Button(isChinese ? "删除" : "Delete", role: .destructive) {
                if let index = durationPendingDeletion, customDurations.indices.contains(index) {
                    customDurations.remove(at: index)
                }
                durationPendingDeletion = nil
            }
        }
    }
}

private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

private struct SettingsActionButton: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 2) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct SettingsPriorityPreviewRow: View {
    let name: String
    let isBuiltIn: Bool
    let isChinese: Bool
    var onNameChange: ((String) -> Void)?
    var onDelete: (() -> Void)?
    @State private var color: Color
    @State private var isBold = false
    @State private var isUnderlined = false
    @State private var isItalic = false

    init(
        name: String,
        color: Color,
        isBuiltIn: Bool,
        isChinese: Bool,
        onNameChange: ((String) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isChinese = isChinese
        self.onNameChange = onNameChange
        self.onDelete = onDelete
        _color = State(initialValue: color)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isBuiltIn {
                Circle().fill(color).frame(width: 12, height: 12)
            } else {
                CustomPriorityColorPicker(priorityName: name, color: $color)
                    .frame(width: 12, height: 12)
            }
            Spacer().frame(width: 4)
            Toggle(isChinese ? "粗体" : "Bold", isOn: $isBold)
            Toggle(isChinese ? "下划线" : "Underline", isOn: $isUnderlined)
            Toggle(isChinese ? "斜体" : "Italic", isOn: $isItalic)
            Spacer(minLength: 8)
            if let onNameChange {
                TextField("", text: Binding(get: { name }, set: onNameChange))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 105, alignment: .trailing)
            } else {
                Text(name).frame(width: 105, alignment: .trailing)
            }
            Spacer(minLength: 8)
            SettingsTrashButton(
                isBuiltIn: isBuiltIn,
                help: isChinese ? "内置优先级不可删除" : "Built-in priorities cannot be deleted",
                action: { onDelete?() }
            )
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(height: 28)
    }
}

private struct SettingsPomodoroPreviewRow: View {
    let totalMinutes: Int
    let isBuiltIn: Bool
    let isChinese: Bool
    var onDelete: (() -> Void)?
    @State private var hours: Int
    @State private var minutes: Int
    @State private var isEditing = false

    init(totalMinutes: Int, isBuiltIn: Bool, isChinese: Bool, onDelete: (() -> Void)? = nil) {
        self.totalMinutes = totalMinutes
        self.isBuiltIn = isBuiltIn
        self.isChinese = isChinese
        self.onDelete = onDelete
        _hours = State(initialValue: totalMinutes / 60)
        _minutes = State(initialValue: totalMinutes % 60)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").foregroundStyle(.secondary)
            Text(durationText)
            Spacer()
            Button {
                isEditing = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(isChinese ? "编辑时长" : "Edit Duration")
            .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(isChinese ? "编辑时长" : "Edit Duration").font(.headline)
                    HStack(spacing: 6) {
                        TextField("0", value: $hours, format: .number).frame(width: 46)
                        Text(isChinese ? "小时" : "Hours")
                        TextField("0", value: $minutes, format: .number).frame(width: 46)
                        Text(isChinese ? "分钟" : "Minutes")
                    }
                    HStack {
                        Spacer()
                        Button(isChinese ? "完成" : "Done") { isEditing = false }
                    }
                }
                .padding(14)
            }
            Spacer(minLength: 16)
            SettingsTrashButton(
                isBuiltIn: isBuiltIn,
                help: isChinese ? "内置时长不可删除" : "Built-in durations cannot be deleted",
                action: { onDelete?() }
            )
        }
        .controlSize(.small)
        .frame(height: 28)
    }

    private var durationText: String {
        isChinese
            ? "\(hours) 小时 \(minutes) 分钟"
            : "\(hours) Hours \(minutes) Minutes"
    }
}

private struct SettingsTrashButton: View {
    let isBuiltIn: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: { if !isBuiltIn { action() } }) {
            Image(systemName: "trash")
                .foregroundStyle(isBuiltIn ? Color.gray : (isHovering ? Color.red : Color.primary))
        }
        .buttonStyle(.borderless)
        .help(isBuiltIn ? help : "")
        .onHover { isHovering = $0 }
        .frame(width: 16)
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
                "",
                text: Binding(
                    get: { preset.name },
                    set: { workspace.updateCustomPomodoroPreset(id: preset.id, name: $0) }
                )
            )
            .textFieldStyle(.plain)
            .disabled(isSystem)
            .frame(width: 120)

            PomodoroDurationFields(preset: preset, isSystem: isSystem)

            Spacer()

            Button(action: onRequestDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(isSystem ? Color.gray : Color.red)
            }
            .buttonStyle(.borderless)
            .disabled(isSystem)
            .help(isSystem ? "默认时间不可删除" : "删除时间")
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

private struct PomodoroDurationFields: View {
    @EnvironmentObject private var workspace: ReminderWorkspace
    let preset: PomodoroDurationPreset
    let isSystem: Bool

    private var hours: Int { preset.totalMinutes / 60 }
    private var minutes: Int { preset.totalMinutes % 60 }

    var body: some View {
        HStack(spacing: 4) {
            TextField(
                "0",
                value: Binding(
                    get: { hours },
                    set: { updateDuration(hours: $0, minutes: minutes) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .disabled(isSystem)

            Text("小时")

            TextField(
                "0",
                value: Binding(
                    get: { minutes },
                    set: { updateDuration(hours: hours, minutes: $0) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .disabled(isSystem)

            Text("分钟")
        }
    }

    private func updateDuration(hours: Int, minutes: Int) {
        let normalizedHours = max(0, hours)
        let normalizedMinutes = min(max(0, minutes), 59)
        let totalSeconds = max(60, (normalizedHours * 60 + normalizedMinutes) * 60)
        workspace.updateCustomPomodoroPreset(id: preset.id, seconds: totalSeconds)
    }
}

private struct SettingsActionLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
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
