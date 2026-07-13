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
private final class PomodoroMenuBarPresenter: NSResponder {
    private static let popoverDismissDelay = 0.3

    private var statusItem: NSStatusItem?
    private var statusView: PomodoroStatusBarView?
    private weak var statusButton: NSStatusBarButton?
    private var statusButtonTrackingArea: NSTrackingArea?
    private var detailsPopover: NSPopover?
    private var activeSession: PomodoroSession?
    private var remainingSeconds = 0
    private var isPointerInsideStatusItem = false
    private var isPointerInsidePopover = false
    private var isDetailsExpanded = false
    private var popoverDismissWorkItem: DispatchWorkItem?
    private var statusWidth = PomodoroMenuBarWidth.defaultValue
    var onExtendDuration: (() -> Void)?
    var onReduceDuration: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onComplete: (() -> Void)?
    var onAbandon: (() -> Void)?

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

        if detailsPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            detailsPopover = popover
        }

        if hasChangedSession || detailsPopover?.contentViewController == nil {
            isDetailsExpanded = false
            updateDetailsPopover()
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
        detailsPopover?.close()
        detailsPopover = nil
        popoverDismissWorkItem?.cancel()
        popoverDismissWorkItem = nil
        isPointerInsideStatusItem = false
        isPointerInsidePopover = false
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
        if detailsPopover?.isShown == true {
            detailsPopover?.close()
        } else {
            showDetails()
        }
    }

    private func showDetails() {
        guard activeSession != nil else {
            return
        }

        guard let popover = detailsPopover else {
            return
        }

        guard !popover.isShown else {
            return
        }

        guard let statusButton else {
            return
        }

        statusButton.layoutSubtreeIfNeeded()
        let anchorRect: NSRect
        if let statusView {
            statusView.layoutSubtreeIfNeeded()
            let progressFrame = statusView.progressBarFrame
            anchorRect = progressFrame.isEmpty
                ? statusButton.bounds
                : statusView.convert(progressFrame, to: statusButton)
        } else {
            anchorRect = statusButton.bounds
        }
        popover.show(relativeTo: anchorRect, of: statusButton, preferredEdge: .minY)
    }

    private func updateDetailsPopover() {
        guard let activeSession else {
            return
        }

        let view = PomodoroStatusPopoverView(
            session: activeSession,
            remainingSeconds: remainingSeconds,
            isExpanded: isDetailsExpanded,
            onToggleExpanded: { [weak self] in
                guard let self else { return }
                self.isDetailsExpanded.toggle()
                self.updateDetailsPopover()
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
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        let contentSize = controller.view.fittingSize
        controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: contentSize.height)
        detailsPopover?.contentViewController = controller
        detailsPopover?.contentSize = NSSize(width: 340, height: contentSize.height)
    }

    private func keepDetailsPopoverVisible() {
        cancelScheduledPopoverDismissal()
        updateDetailsPopover()
        if detailsPopover?.isShown != true {
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
                  !self.isPointerInsideStatusItem,
                  !self.isPointerInsidePopover
            else {
                return
            }

            self.detailsPopover?.close()
            self.popoverDismissWorkItem = nil
        }
        popoverDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popoverDismissDelay, execute: workItem)
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
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.alignment = .right
        timeLabel.textColor = .secondaryLabelColor

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
            : session.taskText.singleLinePrefix
        timeLabel.stringValue = "\(elapsedSeconds.pomodoroElapsedMinutes)/\(session.durationSeconds.pomodoroMinutes)min"
        progressBar.progress = 1 - Double(remainingSeconds) / Double(session.durationSeconds)
        let hasReachedRatioThreshold = Double(remainingSeconds) / Double(session.durationSeconds) <= warningRemainingRatio
        let hasReachedTimeThreshold = remainingSeconds <= warningRemainingMinutes * 60
        progressBar.color = hasReachedRatioThreshold && hasReachedTimeThreshold
            ? .systemRed
            : .controlAccentColor
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
        let trackColor = NSColor.secondaryLabelColor
            .blended(withFraction: 0.18, of: .white) ?? .secondaryLabelColor
        trackColor.setFill()
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

private struct PomodoroStatusPopoverView: View {
    let session: PomodoroSession
    let remainingSeconds: Int
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onExtend: () -> Void
    let onReduce: () -> Void
    let onTogglePause: () -> Void
    let onComplete: () -> Void
    let onAbandon: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(session.listName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

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

                Button(action: onReduce) {
                    Text("-15min")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(remainingSeconds < 20 * 60)
            }

            HStack(spacing: 8) {
                Button(session.pausedAt == nil ? "暂停" : "继续", action: onTogglePause)
                    .buttonStyle(.bordered)
                    .tint(.orange)

                Spacer()

                Button("完成", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                Button("放弃", action: onAbandon)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .onHover(perform: onHoverChange)
    }
}

private extension String {
    var singleLinePrefix: String {
        let value = replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(18))
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
