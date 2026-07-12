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
            .onAppear {
                appDelegate.configureActionMenuAppearance()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                workspace.flushPendingSaves()
            }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("保存当前列表") {
                    workspace.saveSelectedList()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspace.selectedListID == nil)

                Button("Export as PDF…") {
                    workspace.exportSelectedListAsPDF()
                }
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

            CommandMenu("Action") {
                Button(action: {}) {
                    Text("番茄任务")
                        .font(.caption)
                }
                .disabled(true)

                ForEach(workspace.pomodoroPresets.sorted(by: { $0.seconds < $1.seconds })) { preset in
                    Button(preset.menuDisplayName) {
                        workspace.startPomodoroForActiveReminder(presetID: preset.id)
                    }
                    .disabled(!workspace.canStartPomodoroForActiveReminder)
                }
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
                        "显示 \(attribute.displayName)",
                        isOn: Binding(
                            get: { workspace.visibleReminderAttributes.contains(attribute) },
                            set: { workspace.setReminderAttribute(attribute, visible: $0) }
                        )
                    )
                }

                Toggle(
                    "显示 任务序号",
                    isOn: Binding(
                        get: { workspace.showsTaskNumbers },
                        set: { workspace.setShowsTaskNumbers($0) }
                    )
                )

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
                .frame(width: 720)
                .frame(minHeight: 480, idealHeight: 520, maxHeight: .infinity)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyDownMonitor: Any?
    private let actionMenuHeaderStyler = ActionMenuHeaderStyler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [actionMenuHeaderStyler] in
            actionMenuHeaderStyler.apply()
        }

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

    func configureActionMenuAppearance() {
        DispatchQueue.main.async { [actionMenuHeaderStyler] in
            actionMenuHeaderStyler.apply()
        }
    }
}

private final class ActionMenuHeaderStyler: NSObject, NSMenuDelegate {
    func apply() {
        guard let actionMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Action" })?.submenu else {
            return
        }

        actionMenu.delegate = self
        apply(to: actionMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        apply(to: menu)
    }

    private func apply(to actionMenu: NSMenu) {
        guard let pomodoroHeader = actionMenu.items.first(where: {
                  $0.title == "番茄任务" && !$0.isEnabled
              })
        else {
            return
        }

        pomodoroHeader.view = MenuSectionTitleView(title: "番茄任务")
        for item in actionMenu.items where item !== pomodoroHeader {
            item.indentationLevel = 2
        }
    }
}

extension Notification.Name {
    static let reminderFindRequested = Notification.Name("ReminderFindRequested")
}
