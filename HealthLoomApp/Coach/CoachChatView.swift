// CoachChatView.swift
//
// WP-25 (implementation-plan.md): the Coach tab -- message list over the
// view model's turns, token streaming into a draft bubble, input disabled
// while responding, prewarm on appear, stop button, and error/unavailable
// states from `AvailabilityGate`. Each assistant message with a linked
// snapshot carries a "What did the coach see?" expander (summary list here;
// full UI in WP-30). The trailing toolbar slot is reserved for WP-32's tier
// switcher.
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
        NavigationStack {
            // Tab-root scaffold shared with Dashboard/Settings (round-2
            // #12): the app header + tier slot come from the theme, and
            // `isScrollable: false` leaves scrolling to the transcript's
            // own ScrollView (a chat column must not double-scroll).
            ThemedScreen(title: "Coach", isScrollable: false) {
                Text(viewModel.enabledTierNames.isEmpty ? "Off" : viewModel.enabledTierNames)
                    .font(Theme.font(12, .medium, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
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
                    .accessibilityIdentifier("chat.context.\(turn.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

/// The in-flight streaming text. Reads only `draft` (review #11) and owns
/// its own scroll-following, so the transcript above never observes tokens.
private struct CoachDraftSection: View {
    let viewModel: CoachChatViewModel
    let proxy: ScrollViewProxy

    var body: some View {
        Group {
            if !viewModel.draft.isEmpty {
                Text(viewModel.draft)
                    .padding(10)
                    .background(Theme.accentTint)
                    .foregroundStyle(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("chat.message.streaming")
                    .id("draft")
            }
        }
        .onChange(of: viewModel.draft) {
            if !viewModel.draft.isEmpty {
                proxy.scrollTo("draft", anchor: .bottom)
            }
        }
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
