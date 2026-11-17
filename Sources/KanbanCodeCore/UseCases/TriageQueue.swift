import Foundation
import KanbanCodeRemoteKit

// MARK: - Buckets

/// Why a card waits on the user. The raw value is the rank: lower sorts first.
public enum TriageBucket: Int, CaseIterable, Comparable, Sendable, Identifiable {
    /// An open attention request names the card.
    case askedYou = 1
    /// Mid-turn on a permission prompt or a question.
    case blocked
    /// The turn finished.
    case yourTurn
    /// Process alive with nothing recent, for longer than the idle grace.
    case idle
    /// Stopped on a plan usage limit.
    case usageLimited

    public var id: String {
        switch self {
        case .askedYou: "asked_you"
        case .blocked: "blocked"
        case .yourTurn: "your_turn"
        case .idle: "idle"
        case .usageLimited: "usage_limited"
        }
    }

    public var title: String {
        switch self {
        case .askedYou: "Asked you"
        case .blocked: "Blocked"
        case .yourTurn: "Your turn"
        case .idle: "Idle"
        case .usageLimited: "Usage-limited"
        }
    }

    public static func < (lhs: TriageBucket, rhs: TriageBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Snooze

/// Hides a card from the triage queue for a while. Kept by card id in
/// `AppState.triageSnoozes`, persisted by the app (not in links.json).
public struct TriageSnooze: Codable, Sendable, Equatable {
    /// Hidden until this time; nil for a snooze that only waits for a change.
    public var until: Date?
    /// Hidden until the card's activity differs from `stateAtSnooze`.
    public var untilActivityChange: Bool
    /// The card's activity when it was snoozed.
    public var stateAtSnooze: ActivityState?
    /// When it was snoozed: an attention request raised after this breaks it.
    public var snoozedAt: Date

    public init(until: Date?, untilActivityChange: Bool = false, stateAtSnooze: ActivityState? = nil, snoozedAt: Date = .now) {
        self.until = until
        self.untilActivityChange = untilActivityChange
        self.stateAtSnooze = stateAtSnooze
        self.snoozedAt = snoozedAt
    }

    /// Hidden until `until`.
    public static func timed(until: Date, at now: Date = .now) -> TriageSnooze {
        TriageSnooze(until: until, snoozedAt: now)
    }

    /// Hidden until the activity differs from `state`.
    public static func untilChange(from state: ActivityState?, at now: Date = .now) -> TriageSnooze {
        TriageSnooze(until: nil, untilActivityChange: true, stateAtSnooze: state, snoozedAt: now)
    }

    /// Whether it still hides the card. An unknown (nil) activity does not
    /// count as a change: after a relaunch the activity is not known yet.
    public func isActive(activity: ActivityState?, requests: [AttentionRequest], now: Date) -> Bool {
        if requests.contains(where: { $0.isOpen && $0.createdAt > snoozedAt }) { return false }
        if let until, now >= until { return false }
        if untilActivityChange, let activity, activity != stateAtSnooze { return false }
        return until != nil || untilActivityChange
    }

    /// `snoozes` without the expired ones. Cards not among `cards` keep
    /// their snooze unless `dropMissing` (the links are loaded and the card
    /// is gone) or it timed out.
    public static func pruned(
        _ snoozes: [String: TriageSnooze],
        cards: [KanbanCodeCard],
        openRequests: [AttentionRequest],
        dropMissing: Bool,
        now: Date
    ) -> [String: TriageSnooze] {
        guard !snoozes.isEmpty else { return snoozes }
        var requestsByCard: [String: [AttentionRequest]] = [:]
        for request in openRequests {
            guard let cardId = request.cardId, snoozes[cardId] != nil else { continue }
            requestsByCard[cardId, default: []].append(request)
        }
        var seen: Set<String> = []
        var result: [String: TriageSnooze] = [:]
        for card in cards {
            guard let snooze = snoozes[card.id] else { continue }
            seen.insert(card.id)
            if snooze.isActive(activity: card.activityState, requests: requestsByCard[card.id] ?? [], now: now) {
                result[card.id] = snooze
            }
        }
        if !dropMissing {
            for (id, snooze) in snoozes where !seen.contains(id) {
                if let until = snooze.until, now >= until { continue }
                result[id] = snooze
            }
        }
        return result
    }
}

// MARK: - Queue

/// One card waiting on the user.
public struct TriageItem: Identifiable, Sendable, Equatable {
    public var id: String { card.id }
    public let card: KanbanCodeCard
    public let bucket: TriageBucket
    /// Since when it has waited: the oldest open request for *Asked you*,
    /// the last activity change otherwise.
    public let waitingSince: Date
    /// Open attention requests naming the card, oldest first.
    public let requests: [AttentionRequest]
    /// Shown only because snoozed items were asked for.
    public let isSnoozed: Bool
}

/// The cards waiting on the user, ranked by bucket then oldest wait.
public struct TriageQueue: Sendable, Equatable {
    /// An `idleWaiting` card joins the queue only after this long idle.
    public static let idleGrace: TimeInterval = 60

    /// Every item in order: bucket rank, waiting since (oldest first), id.
    public let items: [TriageItem]
    /// The items of each non-empty bucket, in order.
    public let buckets: [TriageBucket: [TriageItem]]
    /// Cards actively working: not items, shown as a strip.
    public let running: [KanbanCodeCard]
    /// Items hidden by an active snooze.
    public let snoozedCount: Int
    /// How long the longest-waiting item has waited.
    public let oldestWait: TimeInterval?

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Builds the queue. `cards` should already pass the project filter.
    /// With `includeSnoozed`, snoozed items are listed too (marked) but
    /// still counted in `snoozedCount`.
    public static func build(
        cards: [KanbanCodeCard],
        openRequests: [AttentionRequest],
        activitySince: [String: Date],
        snoozes: [String: TriageSnooze],
        now: Date,
        includeSnoozed: Bool = false
    ) -> TriageQueue {
        var requestsByCard: [String: [AttentionRequest]] = [:]
        for request in openRequests where request.isOpen {
            guard let cardId = request.cardId else { continue }
            requestsByCard[cardId, default: []].append(request)
        }

        var items: [TriageItem] = []
        var running: [KanbanCodeCard] = []
        var snoozedCount = 0

        for card in cards {
            let link = card.link
            if link.manuallyArchived || link.column == .allSessions { continue }
            let requests = (requestsByCard[card.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            if card.owner != nil && requests.isEmpty { continue }

            let activity = card.activityState
            let activityDate = link.sessionLink.flatMap { activitySince[$0.sessionId] }
                ?? link.lastActivity ?? link.updatedAt

            let bucket: TriageBucket
            let waitingSince: Date
            if let first = requests.first {
                bucket = .askedYou
                waitingSince = first.createdAt
            } else {
                switch activity {
                case .blocked:
                    bucket = .blocked
                case .needsAttention:
                    bucket = .yourTurn
                case .idleWaiting where !link.isAgent && now.timeIntervalSince(activityDate) > idleGrace:
                    bucket = .idle
                case .idleWaiting, .activelyWorking:
                    if card.activeUsageLimit(at: now) != nil {
                        bucket = .usageLimited
                    } else {
                        if activity == .activelyWorking { running.append(card) }
                        continue
                    }
                case .ended, .stale, nil:
                    continue
                }
                waitingSince = activityDate
            }

            var isSnoozed = false
            if let snooze = snoozes[card.id], snooze.isActive(activity: activity, requests: requests, now: now) {
                snoozedCount += 1
                guard includeSnoozed else { continue }
                isSnoozed = true
            }
            items.append(TriageItem(
                card: card, bucket: bucket, waitingSince: waitingSince,
                requests: requests, isSnoozed: isSnoozed))
        }

        items.sort {
            if $0.bucket != $1.bucket { return $0.bucket < $1.bucket }
            if $0.waitingSince != $1.waitingSince { return $0.waitingSince < $1.waitingSince }
            return $0.id < $1.id
        }
        running.sort {
            let a = $0.displayTitle.localizedLowercase, b = $1.displayTitle.localizedLowercase
            return a != b ? a < b : $0.id < $1.id
        }
        let oldest = items.filter { !$0.isSnoozed }.map(\.waitingSince).min()
        return TriageQueue(
            items: items,
            buckets: Dictionary(grouping: items, by: \.bucket),
            running: running,
            snoozedCount: snoozedCount,
            oldestWait: oldest.map { max(0, now.timeIntervalSince($0)) })
    }

    /// The queue of what the board shows: the project-filtered cards.
    public static func build(state: AppState, now: Date, includeSnoozed: Bool = false) -> TriageQueue {
        build(
            cards: state.filteredCards,
            openRequests: state.openAttentionRequests,
            activitySince: state.activitySince,
            snoozes: state.triageSnoozes,
            now: now,
            includeSnoozed: includeSnoozed)
    }

    /// `activitySince` after the activity map goes from `old` to `new`:
    /// stamped `now` where a known state changed, kept where it did not,
    /// dropped for sessions that are gone. A session seen for the first
    /// time gets no stamp, so its wait falls back to its last activity.
    public static func updatedActivitySince(
        _ since: [String: Date],
        old: [String: ActivityState],
        new: [String: ActivityState],
        now: Date
    ) -> [String: Date] {
        var result: [String: Date] = [:]
        for (sessionId, state) in new {
            if let previous = old[sessionId], previous != state {
                result[sessionId] = now
            } else if let kept = since[sessionId] {
                result[sessionId] = kept
            }
        }
        return result
    }
}
