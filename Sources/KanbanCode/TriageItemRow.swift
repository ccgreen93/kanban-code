import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

extension TriageBucket {
    /// The status colour of the bucket, from the card status tones.
    var tone: CardStatusTone {
        switch self {
        case .askedYou, .blocked, .usageLimited: .blocked
        case .yourTurn: .done
        case .idle: .idle
        }
    }
}

extension AttentionRequest {
    /// Vault, biometry and unseal requests are answered only in the
    /// attention sheet, never inline.
    var needsAttentionSheet: Bool {
        requiresBiometry || vault != nil || unseal != nil
    }
}

enum TriageFormat {
    /// Longest message the focused row renders; a huge one is cut here.
    static let messageLimit = 20_000

    /// The first non-empty line, for a one-line preview.
    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// "<1m", "12m", "2h 5m", "3d".
    static func wait(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }

    /// The last `count` non-empty lines of a captured pane.
    static func tail(_ output: String, count: Int = 3) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }
}

/// One item of the triage queue. Unfocused it shows one line of context;
/// focused it adds the terminal tail, the attention options and a composer.
struct TriageItemRow: View {
    let item: TriageItem
    let now: Date
    let isFocused: Bool
    let preview: String?
    let tail: [String]
    @Binding var draft: String
    let composerFocusToken: Int
    var onFocus: () -> Void
    var onOpen: () -> Void
    var onAnswer: (AttentionRequest, Int) -> Void
    var onShowRequest: (AttentionRequest) -> Void
    var onSend: () -> Void
    var onSnooze: (TriageSnoozeChoice) -> Void
    var onUnsnooze: () -> Void
    var onComposerEscape: () -> Void

    private var card: KanbanCodeCard { item.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            context
            if isFocused {
                if let request = item.requests.first {
                    attentionControls(request)
                }
                if !tail.isEmpty {
                    terminalTail
                }
                composer
                hints
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .opacity(item.isSnoozed ? 0.6 : 1)
        .contentShape(Rectangle())
        // The single click focuses at once; a double click also opens.
        .onTapGesture { onFocus() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill((card.statusTone(at: now) ?? item.bucket.tone).color)
                .frame(width: 8, height: 8)
            Text(card.displayTitle)
                .font(.app(.body, weight: .semibold))
                .lineLimit(1)
            Text(location)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let queued = card.link.queuedPrompts, !queued.isEmpty {
                badge("\(queued.count) queued")
            }
            if item.isSnoozed {
                badge("snoozed")
            }
            Spacer(minLength: 8)
            Text("waiting \(TriageFormat.wait(now.timeIntervalSince(item.waitingSince)))")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var location: String {
        [card.projectName, card.link.worktreeLink?.branch].compactMap { $0 }.joined(separator: " · ")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.app(.caption2, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var context: some View {
        if let request = item.requests.first {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.app(.callout, weight: .medium))
                    .lineLimit(isFocused ? 3 : 1)
                if isFocused, !request.body.isEmpty {
                    Text(request.body)
                        .font(.app(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }
        } else if item.bucket == .usageLimited, let limit = card.activeUsageLimit(at: now) {
            Text(limit.resetsAt.map { "Usage limit, resets \($0.formatted(date: .omitted, time: .shortened))" } ?? "Usage limit reached")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
        } else if let preview, !preview.isEmpty {
            if isFocused {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(card.link.effectiveAssistant.displayName):")
                        .font(.app(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        SelectableMarkdownText(
                            content: .markdown(String(preview.prefix(TriageFormat.messageLimit))),
                            appearance: .init(font: .app(.callout), foregroundColor: .secondaryLabelColor)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(card.link.effectiveAssistant.displayName): \u{201C}\(TriageFormat.firstLine(preview))\u{201D}")
                    .font(.app(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func attentionControls(_ request: AttentionRequest) -> some View {
        HStack(spacing: 6) {
            if request.needsAttentionSheet || request.options.isEmpty {
                Button(request.needsAttentionSheet ? "Review in sheet…" : "Open request…") { onShowRequest(request) }
                    .controlSize(.small)
            } else {
                ForEach(Array(request.options.prefix(9).enumerated()), id: \.offset) { index, option in
                    Button { onAnswer(request, index) } label: {
                        Text("\(index + 1)  \(option)")
                    }
                    .controlSize(.small)
                }
                Button("Details…") { onShowRequest(request) }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
            if item.requests.count > 1 {
                badge("+\(item.requests.count - 1) more")
            }
        }
    }

    private var terminalTail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.app(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            PromptEditor(
                text: $draft,
                font: .systemFont(ofSize: NSFont.systemFontSize),
                placeholder: "Reply…  ⌘↩ to send",
                maxHeight: 160,
                identity: card.id,
                onSubmit: { onSend() },
                onCmdSubmit: { onSend() },
                onEscape: { onComposerEscape() },
                focusToken: composerFocusToken
            )
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            Button("Send", action: onSend)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var hints: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("open ↩", action: onOpen)
                .buttonStyle(.borderless)
            if item.isSnoozed {
                Button("unsnooze", action: onUnsnooze)
                    .buttonStyle(.borderless)
            } else {
                Menu("snooze s") {
                    ForEach(TriageSnoozeChoice.allCases, id: \.self) { choice in
                        Button(choice.label) { onSnooze(choice) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .font(.app(.caption))
        .foregroundStyle(.secondary)
    }
}

/// The snoozes the triage view offers.
enum TriageSnoozeChoice: CaseIterable, Hashable {
    case fifteenMinutes
    case oneHour
    case untilChange
    case tomorrowMorning

    var label: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .untilChange: "Until it changes"
        case .tomorrowMorning: "Tomorrow 9 am"
        }
    }

    func snooze(activity: ActivityState?, now: Date, calendar: Calendar = .current) -> TriageSnooze {
        switch self {
        case .fifteenMinutes: return .timed(until: now.addingTimeInterval(15 * 60), at: now)
        case .oneHour: return .timed(until: now.addingTimeInterval(60 * 60), at: now)
        case .untilChange: return .untilChange(from: activity, at: now)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            return .timed(until: nine, at: now)
        }
    }
}
