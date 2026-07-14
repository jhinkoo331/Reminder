import Foundation

struct ReminderMetadata: Decodable {
    let id: String
    let createTime: String
    let deadline: String
    let status: Reminder.Status
    let priority: String?
    let images: [ReminderImageAttachment]?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case createTime = "CreateTime"
        case deadline = "Deadline"
        case status = "Status"
        case priority = "Priority"
        case images = "Images"
    }
}

enum ReminderTextParser {
    static func parse(
        _ source: String,
        configuration: MarkdownTaskConfiguration
    ) -> [Reminder] {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var reminders: [Reminder] = []
        var index = 0

        while index + 1 < lines.count {
            let taskLine = lines[index]
            let metadataLine = lines[index + 1]

            guard let task = markdownTask(from: taskLine),
                  let metadataJSON = metadataJSON(
                      from: metadataLine,
                      expectedIndentation: task.indentation + 6
                  ),
                  let data = metadataJSON.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(ReminderMetadata.self, from: data)
            else {
                index += 1
                continue
            }

            index += 2
            let resolvedStatus = configuration.status(
                metadataStatus: metadata.status,
                checkbox: task.checkbox
            )

            reminders.append(
                Reminder(
                    id: metadata.id,
                    createTime: metadata.createTime,
                    deadline: metadata.deadline,
                    level: task.indentation / 2 + 1,
                    status: resolvedStatus,
                    priorityID: metadata.priority ?? PriorityDefinition.normal.id,
                    text: task.text,
                    images: metadata.images ?? []
                )
            )
        }

        return reminders
    }

    static func serialize(
        _ reminders: [Reminder],
        configuration: MarkdownTaskConfiguration
    ) -> String {
        reminders
            .map { reminder in
                let indentation = String(repeating: " ", count: max(reminder.level - 1, 0) * 2)
                let marker = configuration.checkbox(for: reminder.status).marker
                let taskLine = "\(indentation)- \(marker) \(singleLineText(reminder.text))"
                let metadataIndentation = indentation + String(repeating: " ", count: 6)
                return "\(taskLine)\n\(metadataIndentation)<!-- version: v1 \(metadataJSON(for: reminder)) -->"
            }
            .joined(separator: "\n")
    }

    static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func makeIdentifier(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let suffix = String((0..<6).map { _ in alphabet.randomElement() ?? "0" })
        return "\(formatter.string(from: date))-\(suffix)"
    }

    private static func metadataJSON(for reminder: Reminder) -> String {
        var parts = [
            "\"ID\":\"\(jsonEscaped(reminder.id))\"",
            "\"CreateTime\":\"\(jsonEscaped(reminder.createTime))\"",
            "\"Deadline\":\"\(jsonEscaped(reminder.deadline))\"",
            "\"Status\":\"\(reminder.status.rawValue)\"",
            "\"Priority\":\"\(jsonEscaped(reminder.priorityID))\""
        ]

        if !reminder.images.isEmpty,
           let imagesData = try? JSONEncoder().encode(reminder.images),
           let imagesJSON = String(data: imagesData, encoding: .utf8) {
            parts.append("\"Images\":\(imagesJSON)")
        }

        return "{\(parts.joined(separator: ","))}"
    }

    private static func singleLineText(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func markdownTask(
        from line: String
    ) -> (indentation: Int, checkbox: MarkdownCheckboxState, text: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation.isMultiple(of: 2) else {
            return nil
        }

        let content = String(line.dropFirst(indentation))
        guard content.hasPrefix("- ["), content.count >= 6 else {
            return nil
        }

        let markerStart = content.index(content.startIndex, offsetBy: 3)
        let marker = content[markerStart]
        let closingBracket = content.index(after: markerStart)
        let trailingSpace = content.index(after: closingBracket)
        guard content[closingBracket] == "]",
              content.indices.contains(trailingSpace),
              content[trailingSpace] == " "
        else {
            return nil
        }

        let checkbox: MarkdownCheckboxState
        switch marker {
        case " ": checkbox = .unchecked
        case "x", "X": checkbox = .checked
        default: return nil
        }

        let textStart = content.index(after: trailingSpace)
        return (indentation, checkbox, String(content[textStart...]))
    }

    private static func metadataJSON(
        from line: String,
        expectedIndentation: Int
    ) -> String? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation == expectedIndentation else {
            return nil
        }

        let content = line.dropFirst(indentation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "<!-- version: v1 "
        let suffix = " -->"
        guard content.hasPrefix(prefix), content.hasSuffix(suffix) else {
            return nil
        }

        return String(content.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

extension ReminderWorkspace {
func restoreWorkDirectory() {
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
        let pomodoroPresetLines = customPomodoroPresets.isEmpty
            ? "custom_pomodoro_presets: []"
            : "custom_pomodoro_presets:\n" + customPomodoroPresets
                .map { "  - \(yamlQuoted($0.encodedValue))" }
                .joined(separator: "\n")
        let reminderStatusConfigurationLines = (["statuses:"] + Reminder.Status.allCases.flatMap { status in
            [
                "  \(status.rawValue):",
                "    markdown_checkbox: \(markdownTaskConfiguration.checkbox(for: status).rawValue)"
            ]
        }).joined(separator: "\n")
        let markdownTaskLines = [
            "markdown_task:",
            "  checked_target_status: \(markdownTaskConfiguration.checkedTargetStatus.rawValue)",
            "  unchecked_target_status: \(markdownTaskConfiguration.uncheckedTargetStatus.rawValue)"
        ].joined(separator: "\n")
        let interfaceLines = [
            "interface:",
            "  show_task_numbers: \(showsTaskNumbers)",
            "  copy_task_numbers: \(copiesTaskNumbers)",
            "  copy_sound_enabled: \(playsCopySound)",
            "  completed_task_fade_delay_milliseconds: \(completedTaskFadeDelayMilliseconds)"
        ].joined(separator: "\n")
        let searchLines = [
            "search:",
            "  ignore_case: \(ignoresSearchCase)",
            "  filter_results: \(filtersSearchResults)"
        ].joined(separator: "\n")
        let pomodoroConfigurationLines = [
            "pomodoro:",
            "  warning_remaining_ratio: \(String(format: "%.2f", pomodoroWarningRemainingRatio))",
            "  warning_remaining_minutes: \(pomodoroWarningRemainingMinutes)",
            "  menu_bar_width: \(Int(pomodoroMenuBarWidth))"
        ].joined(separator: "\n")
        let selectedList = selectedListID.map(yamlQuoted) ?? ""
        let header = configurationHeader(for: configurationURL)
        let content = [
            header,
            "version: 2",
            "work_directory: \(yamlQuoted(workDirectoryURL.path(percentEncoded: false)))",
            "display_mode: \(displayMode.rawValue)",
            "color_mode: \(colorMode.rawValue)",
            "interface_scale: \(String(format: "%.1f", interfaceScale))",
            "selected_list_id: \(selectedList)",
            "creation_time_filter: \(creationTimeFilter?.rawValue ?? "none")",
            interfaceLines,
            searchLines,
            pomodoroConfigurationLines,
            attributeLines,
            statusLines,
            reminderStatusConfigurationLines,
            markdownTaskLines,
            defaultPriorityLines,
            customPriorityLines,
            pomodoroPresetLines,
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

    func loadConfiguration() {
        guard let workDirectoryURL else {
            return
        }

        let configurationURL = workDirectoryURL.appendingPathComponent(configurationFileName)
        guard FileManager.default.fileExists(atPath: configurationURL.path(percentEncoded: false)) else {
            customPomodoroPresets = []
            showsTaskNumbers = false
            copiesTaskNumbers = false
            playsCopySound = true
            ignoresSearchCase = true
            filtersSearchResults = true
            pomodoroWarningRemainingRatio = 0.20
            pomodoroWarningRemainingMinutes = 15
            pomodoroMenuBarWidth = PomodoroMenuBarWidth.defaultValue
            creationTimeFilter = nil
            markdownTaskConfiguration = .default
            pomodoro.configureWarningThresholds(
                remainingRatio: pomodoroWarningRemainingRatio,
                remainingMinutes: pomodoroWarningRemainingMinutes
            )
            pomodoro.configureMenuBarWidth(pomodoroMenuBarWidth)
            return
        }

        do {
            let content = try String(contentsOf: configurationURL, encoding: .utf8)
            var selectedList: String?
            var attributes = Set<ReminderAttribute>()
            var statuses: Set<Reminder.Status> = [.todo, .workingOn, .done, .canceled]
            var configuredVersion = 1
            var priorities: [PriorityDefinition] = []
            var configuredDefaults: [PriorityDefinition] = []
            var pomodoroPresets: [PomodoroDurationPreset] = []
            var isReadingAttributes = false
            var isReadingStatuses = false
            var isReadingPriorities = false
            var isReadingDefaultPriorities = false
            var isReadingPomodoroPresets = false
            var isReadingInterface = false
            var isReadingSearch = false
            var isReadingPomodoroConfiguration = false
            var configuredShowsTaskNumbers = false
            var configuredCopiesTaskNumbers = false
            var configuredPlaysCopySound = true
            var configuredCompletedTaskFadeDelayMilliseconds = 3_000
            var configuredIgnoresSearchCase = true
            var configuredFiltersSearchResults = true
            var configuredPomodoroWarningRatio = 0.20
            var configuredPomodoroWarningMinutes = 15
            var configuredPomodoroMenuBarWidth = PomodoroMenuBarWidth.defaultValue
            var configuredCreationTimeFilter: CreationTimeFilter?
            var configuredMarkdownTask = MarkdownTaskConfiguration.default
            var isReadingReminderStatusConfigurations = false
            var isReadingMarkdownTask = false
            var currentConfiguredStatus: Reminder.Status?

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isIndented = line.first?.isWhitespace == true
                let indentation = line.prefix(while: { $0 == " " }).count

                if isReadingReminderStatusConfigurations {
                    if indentation == 2,
                       trimmed.hasSuffix(":"),
                       let status = Reminder.Status(rawValue: String(trimmed.dropLast())) {
                        currentConfiguredStatus = status
                    } else if indentation == 4,
                              let status = currentConfiguredStatus,
                              let value = yamlValue(for: "markdown_checkbox", in: trimmed),
                              let checkbox = MarkdownCheckboxState(rawValue: value) {
                        configuredMarkdownTask.statuses[status] = ReminderStatusConfiguration(
                            markdownCheckbox: checkbox
                        )
                    }
                }

                if isReadingMarkdownTask, isIndented {
                    if let value = yamlValue(for: "checked_target_status", in: trimmed),
                       let status = Reminder.Status(rawValue: value) {
                        configuredMarkdownTask.checkedTargetStatus = status
                    }

                    if let value = yamlValue(for: "unchecked_target_status", in: trimmed),
                       let status = Reminder.Status(rawValue: value) {
                        configuredMarkdownTask.uncheckedTargetStatus = status
                    }
                }

                if isReadingInterface, isIndented {
                    if let value = yamlValue(for: "show_task_numbers", in: trimmed),
                       let enabled = Bool(value) {
                        configuredShowsTaskNumbers = enabled
                    }

                    if let value = yamlValue(for: "copy_task_numbers", in: trimmed),
                       let enabled = Bool(value) {
                        configuredCopiesTaskNumbers = enabled
                    }

                    if let value = yamlValue(for: "copy_sound_enabled", in: trimmed),
                       let enabled = Bool(value) {
                        configuredPlaysCopySound = enabled
                    }

                    if let value = yamlValue(for: "completed_task_fade_delay_milliseconds", in: trimmed),
                       let delay = Int(value) {
                        configuredCompletedTaskFadeDelayMilliseconds = min(max(delay, 0), 5_000)
                    } else if let value = yamlValue(for: "completed_task_fade_delay", in: trimmed),
                              let delay = Double(value) {
                        configuredCompletedTaskFadeDelayMilliseconds = min(
                            max(Int((delay * 1_000).rounded()), 0),
                            5_000
                        )
                    }
                }

                if isReadingSearch, isIndented {
                    if let value = yamlValue(for: "ignore_case", in: trimmed),
                       let enabled = Bool(value) {
                        configuredIgnoresSearchCase = enabled
                    }

                    if let value = yamlValue(for: "filter_results", in: trimmed),
                       let enabled = Bool(value) {
                        configuredFiltersSearchResults = enabled
                    }
                }

                if isReadingPomodoroConfiguration, isIndented {
                    if let value = yamlValue(for: "warning_remaining_ratio", in: trimmed),
                       let ratio = Double(value) {
                        configuredPomodoroWarningRatio = min(max(ratio, 0), 1)
                    }

                    if let value = yamlValue(for: "warning_remaining_minutes", in: trimmed),
                       let minutes = Int(value) {
                        configuredPomodoroWarningMinutes = max(0, minutes)
                    }

                    if let value = yamlValue(for: "menu_bar_width", in: trimmed),
                       let width = Double(value) {
                        configuredPomodoroMenuBarWidth = PomodoroMenuBarWidth.clamped(CGFloat(width))
                    }
                }

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

                if trimmed.hasPrefix("- "), isReadingPomodoroPresets {
                    let rawValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let preset = PomodoroDurationPreset(encodedValue: unquotedYAMLValue(rawValue)) {
                        pomodoroPresets.append(preset)
                    }
                    continue
                }

                isReadingAttributes = trimmed == "visible_attributes:"
                isReadingStatuses = trimmed == "visible_statuses:"
                isReadingPriorities = trimmed == "custom_priorities:"
                isReadingDefaultPriorities = trimmed == "default_priorities:"
                isReadingPomodoroPresets = trimmed == "custom_pomodoro_presets:"
                if !isIndented {
                    isReadingInterface = trimmed == "interface:"
                    isReadingSearch = trimmed == "search:"
                    isReadingPomodoroConfiguration = trimmed == "pomodoro:"
                    isReadingReminderStatusConfigurations = trimmed == "statuses:"
                    isReadingMarkdownTask = trimmed == "markdown_task:"
                    currentConfiguredStatus = nil
                }

                if trimmed == "visible_statuses:" || trimmed == "visible_statuses: []" {
                    statuses = []
                }

                if let value = yamlValue(for: "display_mode", in: trimmed),
                   let mode = DisplayMode(rawValue: value) {
                    displayMode = mode
                }

                if let value = yamlValue(for: "version", in: trimmed),
                   let version = Int(value) {
                    configuredVersion = version
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

                if let value = yamlValue(for: "creation_time_filter", in: trimmed) {
                    configuredCreationTimeFilter = CreationTimeFilter(rawValue: value)
                }
            }

            visibleReminderAttributes = attributes
            if configuredVersion < 2 {
                statuses.insert(.workingOn)
            }
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
            customPomodoroPresets = pomodoroPresets
            showsTaskNumbers = configuredShowsTaskNumbers
            copiesTaskNumbers = configuredShowsTaskNumbers && configuredCopiesTaskNumbers
            playsCopySound = configuredPlaysCopySound
            completedTaskFadeDelayMilliseconds = configuredCompletedTaskFadeDelayMilliseconds
            ignoresSearchCase = configuredIgnoresSearchCase
            filtersSearchResults = configuredFiltersSearchResults
            pomodoroWarningRemainingRatio = configuredPomodoroWarningRatio
            pomodoroWarningRemainingMinutes = configuredPomodoroWarningMinutes
            pomodoroMenuBarWidth = configuredPomodoroMenuBarWidth
            creationTimeFilter = configuredCreationTimeFilter
            configuredMarkdownTask.normalize()
            markdownTaskConfiguration = configuredMarkdownTask
            pomodoro.configureWarningThresholds(
                remainingRatio: configuredPomodoroWarningRatio,
                remainingMinutes: configuredPomodoroWarningMinutes
            )
            pomodoro.configureMenuBarWidth(configuredPomodoroMenuBarWidth)
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

    func uniqueMarkdownFileURL(for requestedName: String, in directoryURL: URL, excluding excludedURL: URL? = nil) -> URL {
        let sanitizedName = sanitizedListName(from: requestedName)
        var candidateURL = directoryURL
            .appendingPathComponent(sanitizedName)
            .appendingPathExtension("md")
            .standardizedFileURL

        let excludedPath = excludedURL?.standardizedFileURL.path(percentEncoded: false)
        if candidateURL.path(percentEncoded: false) == excludedPath {
            return candidateURL
        }

        var suffix = 2
        while FileManager.default.fileExists(atPath: candidateURL.path(percentEncoded: false)) {
            candidateURL = directoryURL
                .appendingPathComponent("\(sanitizedName) \(suffix)")
                .appendingPathExtension("md")
                .standardizedFileURL

            if candidateURL.path(percentEncoded: false) == excludedPath {
                return candidateURL
            }

            suffix += 1
        }

        return candidateURL
    }

    func sanitizedListName(from requestedName: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "/:\\")
        let components = requestedName
            .components(separatedBy: forbiddenCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sanitizedName = components.joined(separator: " ")
        return sanitizedName.isEmpty ? "新建列表" : sanitizedName
    }
}
