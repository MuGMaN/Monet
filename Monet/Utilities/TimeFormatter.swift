import Foundation

/// Utility for formatting time displays
enum TimeFormatter {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"  // "Mon 9:59 PM"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Parse ISO Date

    /// Parse an ISO 8601 date string
    static func parseISO(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        return isoFormatter.date(from: string) ?? isoFormatterNoFractional.date(from: string)
    }

    // MARK: - Compact Time Format

    /// Format time as "H:MM" or "H:MM:SS"
    /// - Parameters:
    ///   - isoString: ISO 8601 date string
    ///   - verbose: If true, includes seconds
    /// - Returns: Formatted string like "2:11" or "2:11:45"
    static func formatCompactTime(from isoString: String?, verbose: Bool = false) -> String? {
        guard let date = parseISO(isoString) else { return nil }
        return formatCompactTime(until: date, verbose: verbose)
    }

    /// Format time interval as "H:MM" or "H:MM:SS"
    static func formatCompactTime(until date: Date, verbose: Bool = false) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "0:00" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if verbose {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", hours, minutes)
        }
    }

    // MARK: - Countdown Format

    /// Format as "2hr 11min" style countdown
    static func formatCountdown(from isoString: String?) -> String? {
        guard let date = parseISO(isoString) else { return nil }
        return formatCountdown(until: date)
    }

    /// Format as "2hr 11min" style countdown
    static func formatCountdown(until date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resetting..." }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)hr \(minutes)min"
        } else {
            return "\(minutes)min"
        }
    }

    // MARK: - DateTime Format

    /// Format as "Mon 9:59 PM" for weekly resets
    static func formatDateTime(from isoString: String?) -> String? {
        guard let date = parseISO(isoString) else { return nil }
        return dateTimeFormatter.string(from: date)
    }

    // MARK: - Relative Format

    /// Format as "1 minute ago", "just now", etc.
    static func formatRelative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Smart Format

    /// Automatically choose format based on time remaining
    /// - Under 24 hours: "2hr 11min"
    /// - Over 24 hours: "Mon 9:59 PM"
    static func formatSmart(from isoString: String?) -> String? {
        guard let date = parseISO(isoString) else { return nil }

        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resetting..." }

        if interval < 24 * 3600 {
            return formatCountdown(until: date)
        } else {
            return dateTimeFormatter.string(from: date)
        }
    }
}
