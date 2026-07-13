import Foundation

enum SmartDateTimeFormatter {
    static func string(
        from timestamp: String,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let parser = formatter(
            format: "yyyy-MM-dd HH:mm:ss",
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        guard let date = parser.date(from: timestamp) else {
            return nil
        }

        return string(from: date, relativeTo: now, calendar: calendar)
    }

    static func string(
        from date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let time = formatted(date, as: "HH:mm", calendar: calendar)

        if abs(date.timeIntervalSince(now)) <= 12 * 60 * 60
            || calendar.isDate(date, inSameDayAs: now) {
            return time
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }

        if let dayBeforeYesterday = calendar.date(byAdding: .day, value: -2, to: now),
           calendar.isDate(date, inSameDayAs: dayBeforeYesterday) {
            return "前天 \(time)"
        }

        let threeMonthsAgo = calendar.date(byAdding: .month, value: -3, to: now)
        let threeMonthsLater = calendar.date(byAdding: .month, value: 3, to: now)
        let isWithinThreeMonths = threeMonthsAgo.map { date >= $0 } == true
            && threeMonthsLater.map { date <= $0 } == true
        let isInCurrentYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)

        if isWithinThreeMonths || isInCurrentYear {
            return formatted(date, as: "MM月dd日 HH:mm", calendar: calendar)
        }

        return formatted(date, as: "yyyy年MM月dd日 HH:mm", calendar: calendar)
    }

    private static func formatted(_ date: Date, as format: String, calendar: Calendar) -> String {
        formatter(format: format, calendar: calendar).string(from: date)
    }

    private static func formatter(
        format: String,
        calendar: Calendar,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }
}
