import Foundation

struct DateUtils {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    static let customFormatterMs: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    
    static let customFormatterMicro: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static let customFormatterSec: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    
    /// Parses an ISO8601 string into a Date, attempting both with and without fractional seconds.
    static func parseDate(from string: String) -> Date? {
        // Core ISO attempts
        if let date = isoFormatter.date(from: string) {
            return date
        }
        if let date = isoFormatterNoFrac.date(from: string) {
            return date
        }
        
        // Strip trailing Z for custom formatters if present
        let cleanString = string.hasSuffix("Z") ? String(string.dropLast()) : string

        // Warn when the string has no timezone designator (no Z, no +hh:mm).
        // This means the caller sent a local time that will be interpreted as UTC — a silent timezone bug.
        let hasTimezoneDesignator = string.hasSuffix("Z") || string.contains("+") || (string.count > 19 && string.dropFirst(19).contains("-"))
        if !hasTimezoneDesignator {
            print("⚠️ [DateUtils] timezone-naive string '\(string)' — interpreting as UTC. Callers must use toUtc().toIso8601String().")
        }

        // Dart specific fallbacks
        if let date = customFormatterMicro.date(from: cleanString) {
            return date
        }
        if let date = customFormatterMs.date(from: cleanString) {
            return date
        }
        if let date = customFormatterSec.date(from: cleanString) {
            return date
        }
        
        print("DateUtils failed to parse string: \(string)")
        return nil
    }
}
