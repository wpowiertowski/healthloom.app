// CoachChatView.swift
//
// WP-25 (implementation-plan.md): the Coach tab -- message list over the
// view model's turns, token streaming into a draft bubble, input disabled
// while responding, prewarm on appear, stop button, a typing indicator
// naming what the coach is doing (WP-78), and error/unavailable
// states from `AvailabilityGate`. Each assistant message with a linked
// snapshot carries a "What did the coach see?" expander (summary list here;
// full UI in WP-30). The trailing toolbar slot is WP-32's tier switcher
// (enabled tiers only; selection re-validated at dispatch).
//
// Render scoping (WP-25 review #5/#11): only the draft bubble reads
// `viewModel.draft`, only the list reads `viewModel.turns` -- a streamed
// token re-renders the bubble, not every row. Snapshot resolution happens
// in row expansion tasks, never during render.

import CoachKit
import CoreModel
import SwiftUI

struct CoachChatView: View {
    @State private var viewModel: CoachChatViewModel

    init(viewModel: CoachChatViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        // Tab-root scaffold shared with Dashboard/Settings (round-2
        // #12): the app header + tier slot come from the theme, and
        // `isScrollable: false` leaves scrolling to the transcript's
        // own ScrollView (a chat column must not double-scroll).
        ThemedScreen(title: "Coach", isScrollable: false) {
            // WP-32 tier switcher: the slot text (unchanged copy +
            // identifier, so existing tests keep passing) is the menu
            // label; the menu offers enabled tiers only — a tier that
            // cannot serve never appears, and `selectTier` re-validates
            // stale picks (blocked at dispatch, not just at the menu).
            Menu {
                if viewModel.enabledTiers.isEmpty {
                    Text("No tiers available")
                } else {
                    ForEach(viewModel.enabledTiers) { tier in
                        Button {
                            viewModel.selectTier(tier)
                        } label: {
                            if viewModel.selectedTier == tier {
                                Label(tier.displayName, systemImage: "checkmark")
                            } else {
                                Text(tier.displayName)
                            }
                        }
                        .accessibilityIdentifier("chat.tier.\(tier.rawValue)")
                    }
                }
            } label: {
                Text(viewModel.enabledTierNames.isEmpty ? "Off" : viewModel.enabledTierNames)
                    .font(Theme.font(Theme.Step.caption, .medium, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    // WP-37: 44pt target for the menu label (audit-small).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            // Identifier on the Menu (not the label Text): labeling
            // both reports the id twice and every lookup goes
            // ambiguous — the menu's own label still carries the
            // slot text the existing tests assert on.
            .accessibilityIdentifier("chat.tierSlot")
        } content: {
            VStack(spacing: 0) {
                if viewModel.availability != .available {
                    ThemedCallout(
                        title: "Coach unavailable",
                        message: [viewModel.availability.userMessage, viewModel.availability.fallbackSuggestion]
                            .filter { !$0.isEmpty }
                            .joined(separator: " "),
                        accessibilityIdentifier: "chat.unavailable"
                    )
                    .padding(.vertical)
                }
                CoachTurnList(viewModel: viewModel)
                if let errorMessage = viewModel.errorMessage {
                    ThemedErrorText(message: errorMessage, accessibilityIdentifier: "chat.error")
                }
                inputBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.contain` (not the default): the screen identifier must
            // NOT override the children's own identifiers (`chat.input`,
            // `chat.send`, ...) the UI tests query -- without this the
            // container collapses them all to `chat.screen`.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.screen")
            .onAppear { viewModel.onAppear() }
            .onDisappear { viewModel.onDisappear() }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField(
                viewModel.availability == .available ? "Message the coach…" : "Coach unavailable",
                text: $viewModel.inputText
            )
            .textFieldStyle(.roundedBorder)
            .disabled(!canSend)
            .accessibilityIdentifier("chat.input")
            if viewModel.isResponding {
                Button("Stop", action: { viewModel.stop() })
                    .accessibilityIdentifier("chat.stop")
                    // WP-37: 44pt target for the text button (audit-small).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            } else {
                Button("Send") {
                    // `send` reports whether the turn was queued; a `false`
                    // (failed save, became unavailable) keeps the typed text
                    // for resubmission (review #4).
                    if viewModel.send(viewModel.inputText) {
                        viewModel.inputText = ""
                    }
                }
                .disabled(!canSend || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat.send")
                // WP-37: 44pt target for the text button (audit-small).
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical)
    }

    private var canSend: Bool {
        viewModel.availability == .available && !viewModel.isResponding
    }
}

/// The scrollable transcript. Reads only `turns`, so streamed tokens never
/// re-evaluate it (review #11); the draft bubble is a sibling that reads
/// only `draft`.
private struct CoachTurnList: View {
    let viewModel: CoachChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.turns) { turn in
                        CoachTurnRow(turn: turn, viewModel: viewModel)
                            .id(turn.id)
                    }
                    CoachDraftSection(viewModel: viewModel, proxy: proxy)
                }
                .padding()
            }
            .onChange(of: viewModel.turns.count) {
                if let last = viewModel.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct CoachTurnRow: View {
    let turn: ChatTurn
    let viewModel: CoachChatViewModel

    var body: some View {
        let isUser = turn.role == "user"
        let alignment: HorizontalAlignment = isUser ? .trailing : .leading
        let frameAlignment: Alignment = isUser ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 4) {
            Text(turn.content)
                .padding(10)
                .background(isUser ? Theme.accent : Theme.accentTint)
                .foregroundStyle(isUser ? .white : Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier(isUser ? "chat.message.user" : "chat.message.assistant")
            if !isUser, turn.contextSnapshotID != nil {
                CoachContextExpander(turn: turn, viewModel: viewModel)
                    // Identifier-carrying parent of identified children:
                    // without `.contain` FIRST, the row identifier collapses
                    // the tier badge's (`chat.context.tier`) — the same
                    // framework corner `AIModelsView`'s header documents.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chat.context.\(turn.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

/// The in-flight reply: the streaming text, and the typing indicator for
/// as long as the coach is responding (WP-78) -- named ("Thinking…",
/// "Reading workout 2…") until text arrives or while a tool runs, bare
/// dots under the text otherwise. Reads only the draft and activity
/// (review #11) and owns its own scroll-following, so the transcript
/// above never observes tokens.
private struct CoachDraftSection: View {
    let viewModel: CoachChatViewModel
    let proxy: ScrollViewProxy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.draft.isEmpty {
                Text(viewModel.draft)
                    .padding(10)
                    .background(Theme.accentTint)
                    .foregroundStyle(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("chat.message.streaming")
            }
            if viewModel.isResponding {
                let named = viewModel.draft.isEmpty || !viewModel.toolActivity.isEmpty
                CoachActivityIndicator(label: named ? viewModel.activityLabel : nil)
            }
        }
        .id("draft")
        .onChange(of: viewModel.draft) {
            if !viewModel.draft.isEmpty {
                proxy.scrollTo("draft", anchor: .bottom)
            }
        }
        .onChange(of: viewModel.isResponding) {
            if viewModel.isResponding {
                proxy.scrollTo("draft", anchor: .bottom)
            }
        }
    }
}

/// Three dots pulsing in turn, with what the coach is doing beside them in
/// a reply bubble; bare dots when `label` is nil (the reply is already
/// streaming). Still under Reduce Motion.
struct CoachActivityIndicator: View {
    let label: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            CoachActivityBubble(label: label, lit: nil)
        } else {
            TimelineView(.periodic(from: .now, by: 0.4)) { context in
                CoachActivityBubble(label: label, lit: Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3)
            }
        }
    }
}

/// One frame of the indicator: `lit` is the dot at full strength (nil:
/// all even). VoiceOver reads the label, not the dots.
struct CoachActivityBubble: View {
    let label: String?
    let lit: Int?

    var body: some View {
        // Dots beside the label's first line, however it wraps.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CoachTypingDots(lit: lit)
            if let label {
                Text(label)
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, label == nil ? 4 : 10)
        .padding(.vertical, label == nil ? 2 : 10)
        .background(label == nil ? Color.clear : Theme.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "The coach is still replying")
        .accessibilityIdentifier("chat.activity")
    }
}

/// The indicator's dots; `lit` is the one at full strength (nil: all even).
private struct CoachTypingDots: View {
    let lit: Int?
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 6

    var body: some View {
        // Read here: the alignment closure is Sendable and can't touch the
        // view's main-actor state. Lifts the dots to the text's middle.
        let lift = size * 0.15
        HStack(spacing: size * 0.6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.secondary)
                    .frame(width: size, height: size)
                    .opacity(lit == nil || lit == index ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.3), value: lit)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + lift }
    }
}

/// Per-message "What did the coach see?" expander. Visibility is decided
/// from `contextSnapshotID != nil` alone; the snapshot fetch + decode runs
/// in the expansion task, never during render (review #5). A linked
/// snapshot that no longer resolves (pruned) reports itself as such.
private struct CoachContextExpander: View {
    let turn: ChatTurn
    let viewModel: CoachChatViewModel

    @State private var isExpanded = false
    @State private var shared: [String]?

    var body: some View {
        DisclosureGroup("What did the coach see?", isExpanded: $isExpanded) {
            // WP-30 trace badge (D15.b — "…and where did it run?"): the
            // serving tier persisted on the turn (`ChatTurn.provider`).
            // WP-30 F2: hidden for an empty provider (free-`String` field —
            // a missed writer must not render a trailing "Served by ");
            // non-empty unknowns keep the raw-string fallback so WP-32's
            // future stamps stay readable.
            if !turn.provider.isEmpty {
                Text("Served by \(ModelTier(rawValue: turn.provider)?.displayName ?? turn.provider)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.context.tier")
            }
            if let shared {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(shared.count) fields shared")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(shared, id: \.self) { field in
                        Text("• \(field)")
                            .font(.footnote)
                    }
                }
            } else {
                Text("Context no longer stored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .task(id: isExpanded) {
            if isExpanded {
                shared = viewModel.resolveSharedContext(for: turn)
            }
        }
    }
}
