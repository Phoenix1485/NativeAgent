import Foundation

/// Presentation and discrete slider mapping; available levels always come from the provider.
enum ModelEffort {
    static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    static func levels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted {
            let left = order.firstIndex(of: $0) ?? order.count
            let right = order.firstIndex(of: $1) ?? order.count
            return left == right ? $0 < $1 : left < right
        }
    }

    static func title(_ value: String) -> String {
        switch value {
        case "": "Auto"
        case "none": "No thinking"
        case "xhigh": "Extra high"
        case "max": "Maximum"
        default: value.capitalized
        }
    }

    static func index(at fraction: Double, count: Int) -> Int? {
        guard count > 0, fraction.isFinite else { return nil }
        return Int((min(1, max(0, fraction)) * Double(count - 1)).rounded())
    }
}
