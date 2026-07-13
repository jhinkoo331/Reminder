import AppKit
import SwiftUI

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
    let onCancelSelection: () -> Void
    let onBeginEditing: () -> Void
    let onPasteImage: (ReminderClipboardImage) -> Void
    let playsCopySound: Bool
    let onCopy: () -> Void
    let priorityDefinitions: [PriorityDefinition]
    let selectedPriorityID: String
    let onSelectPriority: (String) -> Void
    let selectedStatus: Reminder.Status
    let onSelectStatus: (Reminder.Status) -> Void
    let pomodoroPresets: [PomodoroDurationPreset]
    let onStartPomodoro: (String) -> Void
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
        textView.onPasteImage = onPasteImage
        textView.playsCopySound = playsCopySound
        textView.onCopy = onCopy
        textView.isSelectionMode = isSelectionMode
        textView.priorityDefinitions = priorityDefinitions
        textView.selectedPriorityID = selectedPriorityID
        textView.onSelectPriority = onSelectPriority
        textView.selectedStatus = selectedStatus
        textView.onSelectStatus = onSelectStatus
        textView.pomodoroPresets = pomodoroPresets
        textView.onStartPomodoro = onStartPomodoro
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
        nsView.onPasteImage = onPasteImage
        nsView.playsCopySound = playsCopySound
        nsView.onCopy = onCopy
        nsView.isSelectionMode = isSelectionMode
        nsView.priorityDefinitions = priorityDefinitions
        nsView.selectedPriorityID = selectedPriorityID
        nsView.onSelectPriority = onSelectPriority
        nsView.selectedStatus = selectedStatus
        nsView.onSelectStatus = onSelectStatus
        nsView.pomodoroPresets = pomodoroPresets
        nsView.onStartPomodoro = onStartPomodoro
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

            return reminderTextView.handleTextCommand(commandSelector)
        }
    }
}

final class MenuSectionTitleView: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 14))

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class ReminderEditingTextView: NSTextView {
    var onReturn: ((Bool) -> Void)?
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
    var onPasteImage: ((ReminderClipboardImage) -> Void)?
    var playsCopySound = true
    var onCopy: (() -> Void)?
    var isSelectionMode = false
    var priorityDefinitions: [PriorityDefinition] = PriorityDefinition.defaults
    var selectedPriorityID = PriorityDefinition.normal.id
    var onSelectPriority: ((String) -> Void)?
    var selectedStatus: Reminder.Status = .todo
    var onSelectStatus: ((Reminder.Status) -> Void)?
    var pomodoroPresets: [PomodoroDurationPreset] = []
    var onStartPomodoro: ((String) -> Void)?
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

        menu.addItem(sectionTitle("番茄任务"))
        for preset in pomodoroPresets.sorted(by: { $0.seconds < $1.seconds }) {
            let item = NSMenuItem(
                title: preset.menuDisplayName,
                action: #selector(startPomodoro(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.id
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(sectionTitle("Status"))
        for status in [Reminder.Status.todo, .workingOn, .done, .canceled] {
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

        menu.addItem(sectionTitle("Priority"))
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

    private func sectionTitle(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = MenuSectionTitleView(title: title)
        return item
    }

    @objc private func copyReminderText() {
        onCopy?()
    }

    @objc private func requestDelete() {
        onDelete?()
    }

    @objc private func startPomodoro(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? String else {
            return
        }

        onStartPomodoro?(presetID)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            onToggleSelection?()
            return
        }

        super.mouseDown(with: event)
        onBeginEditing?()
    }

    override func paste(_ sender: Any?) {
        guard !isSelectionMode,
              let image = ReminderClipboardImageReader.read()
        else {
            super.paste(sender)
            return
        }

        onPasteImage?(image)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length == 0 else {
            super.copy(sender)
            if playsCopySound {
                ReminderCopySound.play()
            }
            return
        }

        onCopy?()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        guard didResign, selectedRange().length > 0 else {
            return didResign
        }

        let textLength = (string as NSString).length
        let caretLocation = min(selectedRange().location, textLength)
        setSelectedRange(NSRange(location: caretLocation, length: 0))
        return true
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
        // 输入法组合文字必须先交给 macOS 文本输入系统处理。例如拼音输入期间的
        // Return 用于确认候选或提交字母，不能被解释为“创建新任务”。
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let navigationModifiers = modifiers.subtracting([.numericPad, .function])

        if (modifiers == .control || modifiers == .command), event.keyCode == 8 {
            copy(nil)
            return
        }

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

    func handleTextCommand(_ selector: Selector) -> Bool {
        guard !hasMarkedText() else {
            return false
        }

        switch NSStringFromSelector(selector) {
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
            let range = selectedRange()
            onReturn?(range.length == 0 && range.location == 0)
            return true
        default:
            break
        }

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
