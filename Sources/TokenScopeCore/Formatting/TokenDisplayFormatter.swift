import Foundation

public enum TokenDisplayFormatter {
    public static func exact(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func hundredMillions(_ value: Int) -> String {
        guard value != 0 else { return "0" }

        let scaled = Double(value) / 100_000_000
        let magnitude = abs(scaled)

        if magnitude >= 100 {
            return String(format: "%.0f亿", scaled)
        }
        if magnitude >= 10 {
            return String(format: "%.1f亿", scaled)
        }
        if magnitude >= 0.01 {
            return String(format: "%.2f亿", scaled)
        }
        if magnitude >= 0.001 {
            return String(format: "%.3f亿", scaled)
        }
        if magnitude >= 0.0001 {
            return String(format: "%.4f亿", scaled)
        }
        return value > 0 ? "<0.0001亿" : ">-0.0001亿"
    }

    public static func usageSummary(_ value: Int) -> String {
        value == 0 ? "0亿" : hundredMillions(value)
    }
}
