import Foundation

/// How urgent a card is, set by the user. A card without one has no
/// priority and shows no marker.
public enum CardPriority: String, Codable, Sendable, CaseIterable, Comparable {
    case urgent
    case high
    case medium
    case low

    public var label: String {
        switch self {
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// Higher = more urgent.
    public var rank: Int {
        switch self {
        case .urgent: 4
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    public static func < (lhs: CardPriority, rhs: CardPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}
