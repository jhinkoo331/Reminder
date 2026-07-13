import AppKit
import Foundation
import SwiftUI

enum PomodoroMenuBarWidth {
    static let minimum: CGFloat = 160
    static let defaultValue: CGFloat = 250
    static let maximum: CGFloat = 400

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum)
    }
}

struct PomodoroDurationPreset: Identifiable, Hashable {
    static let defaults = [
        PomodoroDurationPreset(id: "default-15m", name: "15分钟", seconds: 15 * 60, isSystem: true),
        PomodoroDurationPreset(id: "default-30m", name: "30分钟", seconds: 30 * 60, isSystem: true),
        PomodoroDurationPreset(id: "default-1h", name: "1小时", seconds: 60 * 60, isSystem: true),
        PomodoroDurationPreset(id: "default-2h", name: "2小时", seconds: 2 * 60 * 60, isSystem: true)
    ]

    let id: String
    var name: String
    var seconds: Int
    let isSystem: Bool

    var encodedValue: String {
        "\(id)|\(name)|\(seconds)"
    }

    init(id: String, name: String, seconds: Int, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.seconds = max(seconds, 60)
        self.isSystem = isSystem
    }

    init?(encodedValue: String) {
        let values = encodedValue.split(separator: "|", maxSplits: 2).map(String.init)
        guard values.count == 3,
              let seconds = Int(values[2]),
              seconds >= 60,
              !values[0].isEmpty,
              !values[1].isEmpty
        else {
            return nil
        }

        self.init(id: values[0], name: values[1], seconds: seconds)
    }

    var totalMinutes: Int {
        max(1, seconds / 60)
    }

    var menuDisplayName: String {
        let totalMinutes = max(1, seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(minutes) min"
        }
        if minutes == 0 {
            return "\(hours) h"
        }
        return "\(hours) h \(minutes) min"
    }
}

struct PomodoroSession: Identifiable, Equatable {
    let id = UUID()
    let listID: ReminderListFile.ID
    let reminderID: Reminder.ID
    let listName: String
    let taskText: String
    var durationSeconds: Int
    let startedAt: Date
    var accumulatedPauseSeconds: TimeInterval = 0
    var pausedAt: Date?
}

@MainActor
final class PomodoroController: ObservableObject {
    @Published private(set) var activeSession: PomodoroSession?
    @Published private(set) var remainingSeconds = 0

    private var timer: Timer?
    private let menuBarPresenter: PomodoroMenuBarPresenter
    private var warningRemainingRatio = 0.20
    private var warningRemainingMinutes = 10
    var onCompleteTask: ((ReminderListFile.ID, Reminder.ID) -> Void)?
    var onOpenList: ((ReminderListFile.ID) -> Void)?

    init() {
        menuBarPresenter = PomodoroMenuBarPresenter()
        menuBarPresenter.onExtendDuration = { [weak self] in
            self?.extendActiveSession(by: 15 * 60)
        }
        menuBarPresenter.onReduceDuration = { [weak self] in
            self?.reduceActiveSession(by: 15 * 60)
        }
        menuBarPresenter.onTogglePause = { [weak self] in
            self?.togglePause()
        }
        menuBarPresenter.onComplete = { [weak self] in
            self?.completeActiveSession()
        }
        menuBarPresenter.onAbandon = { [weak self] in
            self?.cancel()
        }
        menuBarPresenter.onOpenList = { [weak self] in
            guard let self, let activeSession = self.activeSession else {
                return
            }
            self.onOpenList?(activeSession.listID)
        }
    }

    func configureWarningThresholds(remainingRatio: Double, remainingMinutes: Int) {
        warningRemainingRatio = min(max(remainingRatio, 0), 1)
        warningRemainingMinutes = max(0, remainingMinutes)
        refreshMenuBar()
    }

    func configureWarningThresholds(remainingRatio: Double, remainingMinutes: Int, refresh: Bool) {
        warningRemainingRatio = min(max(remainingRatio, 0), 1)
        warningRemainingMinutes = max(0, remainingMinutes)
        if refresh {
            refreshMenuBar()
        }
    }

    func configureMenuBarWidth(_ width: CGFloat) {
        menuBarPresenter.setStatusWidth(width)
    }

    func start(
        listID: ReminderListFile.ID,
        listName: String,
        reminder: Reminder,
        preset: PomodoroDurationPreset
    ) {
        let session = PomodoroSession(
            listID: listID,
            reminderID: reminder.id,
            listName: listName,
            taskText: reminder.text,
            durationSeconds: preset.seconds,
            startedAt: Date()
        )

        activeSession = session
        remainingSeconds = preset.seconds
        startTimer()
        refreshMenuBar()
    }

    func extendActiveSession(by seconds: Int) {
        guard seconds > 0, var session = activeSession else {
            return
        }

        session.durationSeconds += seconds
        activeSession = session
        remainingSeconds = calculateRemainingSeconds(for: session)
        if remainingSeconds > 0, timer == nil {
            startTimer()
        }
        refreshMenuBar()
    }

    func reduceActiveSession(by seconds: Int) {
        guard seconds > 0,
              remainingSeconds >= 20 * 60,
              var session = activeSession
        else {
            return
        }

        let elapsedSeconds = elapsedSeconds(for: session)
        session.durationSeconds = max(elapsedSeconds, session.durationSeconds - seconds)
        activeSession = session
        remainingSeconds = max(0, session.durationSeconds - elapsedSeconds)

        if remainingSeconds == 0 {
            cancel()
        } else {
            refreshMenuBar()
        }
    }

    func togglePause() {
        guard var session = activeSession else {
            return
        }

        if let pausedAt = session.pausedAt {
            session.accumulatedPauseSeconds += Date().timeIntervalSince(pausedAt)
            session.pausedAt = nil
        } else {
            session.pausedAt = Date()
        }

        activeSession = session
        refreshMenuBar()
    }

    func completeActiveSession() {
        guard let session = activeSession else {
            return
        }

        onCompleteTask?(session.listID, session.reminderID)
        cancel()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        activeSession = nil
        remainingSeconds = 0
        menuBarPresenter.hide()
    }

    func isActive(listID: ReminderListFile.ID, reminderID: Reminder.ID) -> Bool {
        activeSession?.listID == listID && activeSession?.reminderID == reminderID
    }

    var hasRunningSession: Bool {
        activeSession != nil && remainingSeconds > 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let activeSession else {
            cancel()
            return
        }

        remainingSeconds = calculateRemainingSeconds(for: activeSession)

        if remainingSeconds == 0 {
            timer?.invalidate()
            timer = nil
            refreshMenuBar()
        } else {
            refreshMenuBar()
        }
    }

    private func refreshMenuBar() {
        guard let activeSession else {
            return
        }

        menuBarPresenter.show(
            session: activeSession,
            remainingSeconds: remainingSeconds,
            warningRemainingRatio: warningRemainingRatio,
            warningRemainingMinutes: warningRemainingMinutes
        )
    }

    private func elapsedSeconds(for session: PomodoroSession) -> Int {
        let currentPauseSeconds = session.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = Date().timeIntervalSince(session.startedAt)
            - session.accumulatedPauseSeconds
            - currentPauseSeconds
        return max(0, Int(elapsed.rounded(.down)))
    }

    private func calculateRemainingSeconds(for session: PomodoroSession) -> Int {
        max(0, session.durationSeconds - elapsedSeconds(for: session))
    }
}

@MainActor
private final class PomodoroCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PomodoroMenuBarPresenter: NSResponder, NSWindowDelegate {
    private static let popoverDismissDelay = 0.3

    private var statusItem: NSStatusItem?
    private var statusView: PomodoroStatusBarView?
    private weak var statusButton: NSStatusBarButton?
    private var statusButtonTrackingArea: NSTrackingArea?
    private var detailsPanel: PomodoroCardPanel?
    private var detailsHostingController: NSHostingController<PomodoroStatusCardView>?
    private var floatingPanel: PomodoroCardPanel?
    private var floatingHostingController: NSHostingController<PomodoroStatusCardView>?
    private var activeSession: PomodoroSession?
    private var remainingSeconds = 0
    private var warningRemainingRatio = 0.20
    private var warningRemainingMinutes = 10
    private var isPointerInsideStatusItem = false
    private var isPointerInsidePopover = false
    private var isDetailsExpanded = false
    private var isDetailsOpenedByClick = false
    private var isPinned = false
    private var popoverDismissWorkItem: DispatchWorkItem?
    private var statusWidth = PomodoroMenuBarWidth.defaultValue
    var onExtendDuration: (() -> Void)?
    var onReduceDuration: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onComplete: (() -> Void)?
    var onAbandon: (() -> Void)?
    var onOpenList: (() -> Void)?

    func setStatusWidth(_ width: CGFloat) {
        statusWidth = PomodoroMenuBarWidth.clamped(width)
        statusItem?.length = statusWidth
    }

    func show(
        session: PomodoroSession,
        remainingSeconds: Int,
        warningRemainingRatio: Double,
        warningRemainingMinutes: Int
    ) {
        let hasChangedSession = activeSession?.id != session.id
        activeSession = session
        self.remainingSeconds = remainingSeconds
        self.warningRemainingRatio = warningRemainingRatio
        self.warningRemainingMinutes = warningRemainingMinutes
        let item: NSStatusItem
        if let statusItem {
            item = statusItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: statusWidth)
            statusItem = item
            let view = PomodoroStatusBarView()
            statusView = view

            if let button = item.button {
                statusButton = button
                button.title = ""
                button.image = nil
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.sendAction(on: [.leftMouseUp])

                let trackingArea = NSTrackingArea(
                    rect: button.bounds,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                button.addTrackingArea(trackingArea)
                statusButtonTrackingArea = trackingArea

                button.addSubview(view)
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    view.topAnchor.constraint(equalTo: button.topAnchor),
                    view.bottomAnchor.constraint(equalTo: button.bottomAnchor)
                ])
            }
        }

        item.length = statusWidth

        statusView?.update(
            session: session,
            remainingSeconds: remainingSeconds,
            warningRemainingRatio: warningRemainingRatio,
            warningRemainingMinutes: warningRemainingMinutes
        )
        item.button?.toolTip = session.taskText

        if isPinned {
            if hasChangedSession {
                isDetailsExpanded = false
            }
            updateFloatingPanel()
            return
        }

        if hasChangedSession {
            isDetailsExpanded = false
        }
        if hasChangedSession
            || detailsPanel?.contentViewController == nil
            || detailsPanel?.isVisible == true {
            updateDetailsPanel()
        }
    }

    func hide() {
        guard let statusItem else {
            return
        }

        if let statusButtonTrackingArea, let statusButton {
            statusButton.removeTrackingArea(statusButtonTrackingArea)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusView = nil
        statusButton = nil
        statusButtonTrackingArea = nil
        detailsPanel?.close()
        detailsPanel = nil
        detailsHostingController = nil
        floatingPanel?.close()
        floatingPanel = nil
        floatingHostingController = nil
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil
        isPointerInsideStatusItem = false
        isPointerInsidePopover = false
        isDetailsOpenedByClick = false
        isPinned = false
        activeSession = nil
        remainingSeconds = 0
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInsideStatusItem = true
        cancelScheduledPopoverDismissal()
        showDetails()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInsideStatusItem = false
        schedulePopoverDismissal()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        cancelScheduledPopoverDismissal()
        if isPinned {
            floatingPanel?.makeKeyAndOrderFront(nil)
            return
        }

        if let detailsPanel, detailsPanel.isVisible {
            if isDetailsOpenedByClick {
                dismissDetailsPanel()
            } else {
                isDetailsOpenedByClick = true
                positionDetailsPanel(detailsPanel)
                detailsPanel.makeKeyAndOrderFront(nil)
            }
        } else {
            isDetailsOpenedByClick = true
            showDetails(activating: true)
        }
    }

    private func showDetails(activating: Bool = false) {
        guard activeSession != nil else {
            return
        }

        updateDetailsPanel()

        guard let detailsPanel, !detailsPanel.isVisible else {
            return
        }

        positionDetailsPanel(detailsPanel)
        if activating {
            detailsPanel.makeKeyAndOrderFront(nil)
        } else {
            detailsPanel.orderFrontRegardless()
        }
    }

    private func updateDetailsPanel() {
        guard let activeSession else {
            return
        }

        let view = detailsView(for: activeSession)
        let controller: NSHostingController<PomodoroStatusCardView>
        if let detailsHostingController {
            detailsHostingController.rootView = view
            controller = detailsHostingController
        } else {
            let newController = NSHostingController(rootView: view)
            detailsHostingController = newController
            controller = newController
        }
        let contentSize = fitCardContent(controller)
        let panel = detailsPanel ?? makeCardPanel(contentSize: contentSize)
        panel.level = .popUpMenu
        panel.delegate = self
        panel.contentViewController = controller
        panel.setContentSize(contentSize)
        detailsPanel = panel
        if panel.isVisible {
            positionDetailsPanel(panel)
        }
    }

    private func updateFloatingPanel() {
        guard isPinned, let activeSession else {
            return
        }

        let view = detailsView(for: activeSession)
        let controller: NSHostingController<PomodoroStatusCardView>
        if let floatingHostingController {
            floatingHostingController.rootView = view
            controller = floatingHostingController
        } else {
            let newController = NSHostingController(rootView: view)
            floatingHostingController = newController
            controller = newController
        }

        let contentSize = fitCardContent(controller)

        if let floatingPanel {
            let topLeft = NSPoint(x: floatingPanel.frame.minX, y: floatingPanel.frame.maxY)
            floatingPanel.contentViewController = controller
            floatingPanel.setContentSize(contentSize)
            floatingPanel.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - contentSize.height))
            floatingPanel.orderFrontRegardless()
            return
        }

        let panel = makeCardPanel(contentSize: contentSize)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentViewController = controller
        if let detailsPanel {
            panel.setFrameTopLeftPoint(
                NSPoint(x: detailsPanel.frame.minX, y: detailsPanel.frame.maxY)
            )
        } else {
            positionDetailsPanel(panel)
        }
        panel.makeKeyAndOrderFront(nil)
        floatingPanel = panel
    }

    private func makeCardPanel(contentSize: NSSize) -> PomodoroCardPanel {
        let panel = PomodoroCardPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }

    private func positionDetailsPanel(_ panel: NSPanel) {
        guard let statusButton,
              let statusWindow = statusButton.window
        else {
            return
        }

        statusButton.layoutSubtreeIfNeeded()
        let buttonFrame = statusWindow.convertToScreen(
            statusButton.convert(statusButton.bounds, to: nil)
        )
        let visibleFrame = statusWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let horizontalInset: CGFloat = 8
        let proposedX = buttonFrame.midX - panel.frame.width / 2
        let minimumX = visibleFrame.minX + horizontalInset
        let maximumX = visibleFrame.maxX - panel.frame.width - horizontalInset
        let originX = min(max(proposedX, minimumX), max(minimumX, maximumX))
        let originY = buttonFrame.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func fitCardContent(
        _ controller: NSHostingController<PomodoroStatusCardView>
    ) -> NSSize {
        controller.view.layoutSubtreeIfNeeded()
        let contentSize = NSSize(
            width: PomodoroStatusCardView.width,
            height: controller.view.fittingSize.height
        )
        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        return contentSize
    }

    private func detailsView(for session: PomodoroSession) -> PomodoroStatusCardView {
        PomodoroStatusCardView(
            session: session,
            remainingSeconds: remainingSeconds,
            warningRemainingRatio: warningRemainingRatio,
            warningRemainingMinutes: warningRemainingMinutes,
            isExpanded: isDetailsExpanded,
            isPinned: isPinned,
            onOpenList: { [weak self] in
                self?.onOpenList?()
            },
            onToggleExpanded: { [weak self] in
                guard let self else { return }
                self.isDetailsExpanded.toggle()
                if self.isPinned {
                    self.updateFloatingPanel()
                } else {
                    self.updateDetailsPanel()
                }
            },
            onTogglePin: { [weak self] in
                self?.togglePin()
            },
            onExtend: { [weak self] in
                self?.onExtendDuration?()
                self?.keepDetailsPopoverVisible()
            },
            onReduce: { [weak self] in
                self?.onReduceDuration?()
                self?.keepDetailsPopoverVisible()
            },
            onTogglePause: { [weak self] in
                self?.onTogglePause?()
                self?.keepDetailsPopoverVisible()
            },
            onComplete: { [weak self] in
                self?.onComplete?()
            },
            onAbandon: { [weak self] in
                self?.onAbandon?()
            },
            onHoverChange: { [weak self] isInside in
                self?.isPointerInsidePopover = isInside
                if isInside {
                    self?.cancelScheduledPopoverDismissal()
                } else {
                    self?.schedulePopoverDismissal()
                }
            }
        )
    }

    private func togglePin() {
        isPinned.toggle()
        cancelScheduledPopoverDismissal()

        if isPinned {
            isDetailsOpenedByClick = false
            detailsPanel?.orderOut(nil)
            updateFloatingPanel()
        } else {
            floatingPanel?.close()
            floatingPanel = nil
            floatingHostingController = nil
        }
    }

    private func keepDetailsPopoverVisible() {
        cancelScheduledPopoverDismissal()
        if isPinned {
            updateFloatingPanel()
            return
        }
        updateDetailsPanel()
        if detailsPanel?.isVisible != true {
            showDetails()
        }
    }

    private func cancelScheduledPopoverDismissal() {
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil
    }

    private func schedulePopoverDismissal() {
        cancelScheduledPopoverDismissal()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isDetailsOpenedByClick,
                  !self.isPointerInsideStatusItem,
                  !self.isPointerInsidePopover
            else {
                return
            }

            self.detailsPanel?.orderOut(nil)
            self.popoverDismissWorkItem = nil
        }
        popoverDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverDismissDelay, execute: workItem)
    }

    private func dismissDetailsPanel() {
        isDetailsOpenedByClick = false
        detailsPanel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === detailsPanel,
              isDetailsOpenedByClick
        else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isDetailsOpenedByClick,
                  self.detailsPanel?.isKeyWindow != true
            else {
                return
            }
            self.dismissDetailsPanel()
        }
    }
}

private enum PomodoroProgressStyle {
    static var trackColor: NSColor {
        NSColor.secondaryLabelColor
            .blended(withFraction: 0.18, of: .white) ?? .secondaryLabelColor
    }

    static func fraction(remainingSeconds: Int, durationSeconds: Int) -> Double {
        1 - Double(remainingSeconds) / Double(durationSeconds)
    }

    static func color(
        remainingSeconds: Int,
        durationSeconds: Int,
        warningRemainingRatio: Double,
        warningRemainingMinutes: Int
    ) -> NSColor {
        let hasReachedRatioThreshold = Double(remainingSeconds) / Double(durationSeconds)
            <= warningRemainingRatio
        let hasReachedTimeThreshold = remainingSeconds <= warningRemainingMinutes * 60
        return hasReachedRatioThreshold && hasReachedTimeThreshold
            ? .systemRed
            : .controlAccentColor
    }
}

private final class PomodoroStatusBarView: NSView {
    private let taskLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let progressBar = PomodoroProgressBar()
    var progressBarFrame: NSRect {
        progressBar.frame
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        taskLabel.font = .systemFont(ofSize: 10, weight: .medium)
        taskLabel.lineBreakMode = .byTruncatingTail
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.alignment = .right
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let labels = NSStackView(views: [taskLabel, timeLabel])
        labels.orientation = .horizontal
        labels.alignment = .centerY
        labels.spacing = 6
        labels.distribution = .fill
        labels.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labels)
        addSubview(progressBar)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            timeLabel.widthAnchor.constraint(equalToConstant: 64),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            progressBar.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 1),
            progressBar.heightAnchor.constraint(equalToConstant: 5),
            progressBar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -1)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        session: PomodoroSession,
        remainingSeconds: Int,
        warningRemainingRatio: Double,
        warningRemainingMinutes: Int
    ) {
        let elapsedSeconds = max(0, session.durationSeconds - remainingSeconds)
        taskLabel.stringValue = remainingSeconds == 0
            ? "已结束"
            : session.taskText.singleLineDisplay
        timeLabel.stringValue = "\(elapsedSeconds.pomodoroElapsedMinutes)/\(session.durationSeconds.pomodoroMinutes)min"
        progressBar.progress = PomodoroProgressStyle.fraction(
            remainingSeconds: remainingSeconds,
            durationSeconds: session.durationSeconds
        )
        progressBar.color = PomodoroProgressStyle.color(
            remainingSeconds: remainingSeconds,
            durationSeconds: session.durationSeconds,
            warningRemainingRatio: warningRemainingRatio,
            warningRemainingMinutes: warningRemainingMinutes
        )
    }
}

private final class PomodoroProgressBar: NSView {
    var progress: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }
    var color: NSColor = .controlAccentColor {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let barRect = bounds.insetBy(dx: 0, dy: 0.5)
        let cornerRadius = barRect.height / 2
        PomodoroProgressStyle.trackColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let progressWidth = max(0, min(1, progress)) * barRect.width
        guard progressWidth > 0 else {
            return
        }

        let progressRect = NSRect(x: barRect.minX, y: barRect.minY, width: progressWidth, height: barRect.height)
        color.setFill()
        NSBezierPath(roundedRect: progressRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

private struct PomodoroStatusCardView: View {
    static let width: CGFloat = 340

    @Environment(\.controlActiveState) private var controlActiveState

    let session: PomodoroSession
    let remainingSeconds: Int
    let warningRemainingRatio: Double
    let warningRemainingMinutes: Int
    let isExpanded: Bool
    let isPinned: Bool
    let onOpenList: () -> Void
    let onToggleExpanded: () -> Void
    let onTogglePin: () -> Void
    let onExtend: () -> Void
    let onReduce: () -> Void
    let onTogglePause: () -> Void
    let onComplete: () -> Void
    let onAbandon: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Button(action: onOpenList) {
                    Text(session.listName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("在 Reminder 中打开此文档")

                Spacer()

                Button(action: onTogglePin) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .rotationEffect(.degrees(45))
                        .foregroundStyle(isPinned ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isPinned ? "取消固定卡片" : "固定卡片到桌面")
            }

            PomodoroCardProgressBar(
                remainingSeconds: remainingSeconds,
                durationSeconds: session.durationSeconds,
                warningRemainingRatio: warningRemainingRatio,
                warningRemainingMinutes: warningRemainingMinutes
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(session.taskText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(isExpanded ? nil : 3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if session.taskText.needsExpansion {
                    Button(isExpanded ? "收起" : "展开") {
                        onToggleExpanded()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .focusable(false)
                }
            }

            Text("开始时间：\(session.startedAt.pomodoroDetailDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("预计结束时间：\(session.expectedEndAt.pomodoroDetailDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Spacer()

                Button(action: onExtend) {
                    Text("+15min")
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .focusable(false)

                Button(action: onReduce) {
                    Text("-15min")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(remainingSeconds < 20 * 60)
                .focusable(false)
            }

            HStack(spacing: 8) {
                Button(session.pausedAt == nil ? "暂停" : "继续", action: onTogglePause)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .focusable(false)

                Spacer()

                completionActions
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)

                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.58)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .onHover(perform: onHoverChange)
    }

    @ViewBuilder
    private var completionActions: some View {
        if !isPinned || controlActiveState == .key {
            Button("完成", action: onComplete)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .focusable(false)

            Button("放弃", action: onAbandon)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .focusable(false)
        } else {
            Button("完成", action: onComplete)
                .buttonStyle(.bordered)
                .focusable(false)

            Button("放弃", action: onAbandon)
                .buttonStyle(.bordered)
                .focusable(false)
        }
    }
}

private struct PomodoroCardProgressBar: View {
    let remainingSeconds: Int
    let durationSeconds: Int
    let warningRemainingRatio: Double
    let warningRemainingMinutes: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: PomodoroProgressStyle.trackColor))

                Capsule()
                    .fill(Color(nsColor: progressColor))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 7)
    }

    private var progress: CGFloat {
        CGFloat(
            min(
                max(
                    PomodoroProgressStyle.fraction(
                        remainingSeconds: remainingSeconds,
                        durationSeconds: durationSeconds
                    ),
                    0
                ),
                1
            )
        )
    }

    private var progressColor: NSColor {
        PomodoroProgressStyle.color(
            remainingSeconds: remainingSeconds,
            durationSeconds: durationSeconds,
            warningRemainingRatio: warningRemainingRatio,
            warningRemainingMinutes: warningRemainingMinutes
        )
    }
}

private extension String {
    var singleLineDisplay: String {
        replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var needsExpansion: Bool {
        contains("\n") || count > 96
    }
}

private extension Int {
    var pomodoroMinutes: Int {
        Swift.max(0, Int(ceil(Double(self) / 60)))
    }

    var pomodoroElapsedMinutes: Int {
        Swift.max(0, self / 60)
    }
}

private extension Date {
    var pomodoroDetailDisplay: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: self)
    }
}

private extension PomodoroSession {
    var expectedEndAt: Date {
        let currentPauseSeconds = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return startedAt.addingTimeInterval(
            TimeInterval(durationSeconds) + accumulatedPauseSeconds + currentPauseSeconds
        )
    }
}
