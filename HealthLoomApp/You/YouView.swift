// YouView.swift
//
// WP-30 (implementation-plan.md): the You tab — knowledge transparency.
// Three sections over the persisted `KnowledgeProfile`:
//
//   - Profile: every field (display text, source, as-of) with its AI-context
//     toggle. Clinical fields carry a "Clinical" badge and start excluded
//     (D8); correction-pinned fields carry a "Your correction" badge.
//   - Correct: per-field Edit opens the correction sheet — the saved text
//     pins a user correction that beats re-derivation (see `KnowledgeStore`
//     `pinCorrection`), keeping the field's sharing posture.
//   - Forget: per-field exclusion IS the toggle above; this section holds
//     the two global actions — derived-insight reset and chat-history wipe
//     (both confirmed, both keep source data for re-derivation; the
//     full-data wipe is WP-35's flow).
//
// Accessibility contract the UI tests drive: `you.screen`, per-field
// `you.ai.<key>` toggles, `you.edit.<key>` buttons, `you.correct.*` sheet
// elements, `you.forget.*` buttons. (Field keys contain dots, e.g.
// `steps.dailyAverage` — matched verbatim, exactly as seeded.)

import CoachKit
import CoreModel
import SwiftUI

struct YouView: View {
    // Non-optional `@State` (the `CoachChatView` precedent): the parent
    // builds the VM from `AppEnvironment` (`HomeView` → `youViewModel()`)
    // — `State(initialValue:)` keeps the first instance across re-renders,
    // and a fresh tab visit builds a fresh view (no stale correction state).
    @State private var viewModel: YouViewModel
    /// Field key under correction (nil = no sheet). A key, not a Bool, so
    /// the sheet knows which field it edits.
    @State private var editingKey: String?
    @State private var correctionDraft = ""
    @State private var confirmReset = false
    @State private var confirmWipe = false

    init(viewModel: YouViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ThemedScreen(title: "You") {
            profileSection
            forgetSection
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.font(12, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("you.notice")
            }
            if let error = viewModel.errorMessage {
                ThemedErrorText(message: error, accessibilityIdentifier: "you.error")
                    .padding(.horizontal, 16)
            }
        }
        .accessibilityIdentifier("you.screen")
        .task {
            viewModel.load()
        }
        .sheet(isPresented: Binding(
            get: { editingKey != nil },
            set: { if !$0 { editingKey = nil } }
        )) {
            correctionSheet
        }
        .confirmationDialog(
            "Reset derived insights?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset insights", role: .destructive) { viewModel.resetInsights() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Past insights are deleted. Your profile and chats stay.")
        }
        .confirmationDialog(
            "Erase chat history?",
            isPresented: $confirmWipe,
            titleVisibility: .visible
        ) {
            Button("Erase history", role: .destructive) { viewModel.wipeChatHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message and its shared-context snapshot is deleted. Your profile and insights stay.")
        }
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileSection: some View {
        ThemedSectionHeader(title: "What the coach knows")
        if viewModel.fields.isEmpty {
            ThemedPanel {
                Text("Nothing here yet. Chat with the coach and your profile will appear.")
                    .font(Theme.font(14, .regular, relativeTo: .body))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("you.empty")
            }
        } else {
            ForEach(viewModel.fields, id: \.key) { field in
                ThemedPanel {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(field.displayText)
                                .font(Theme.font(14, .medium, relativeTo: .subheadline))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if field.isClinical {
                                Text("Clinical")
                                    .font(Theme.font(11, .medium, relativeTo: .caption2))
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityIdentifier("you.clinical.\(field.key)")
                            }
                        }
                        Text("\(field.source) · \(field.asOf.formatted(date: .abbreviated, time: .omitted))")
                            .font(Theme.font(12, .regular, relativeTo: .caption))
                            .foregroundStyle(Theme.secondary)
                        if field.source == KnowledgeStore.correctionSourceLabel {
                            Text("Your correction")
                                .font(Theme.font(12, .regular, relativeTo: .caption))
                                .foregroundStyle(Theme.secondary)
                                .accessibilityIdentifier("you.correction.\(field.key)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 11)
                    ThemedRowDivider()
                    HStack {
                        ThemedToggleRow(
                            title: "Use for AI replies",
                            accessibilityIdentifier: "you.ai.\(field.key)",
                            isOn: Binding(
                                get: { !field.excludedFromAI },
                                set: { viewModel.setExcluded(!$0, forKey: field.key) }
                            )
                        )
                        // Fixed size: the Toggle is horizontally greedy and
                        // would otherwise squeeze this button to zero width
                        // (seen as a 0-wide frame in UI tests).
                        Button("Edit") {
                            correctionDraft = field.displayText
                            editingKey = field.key
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("you.edit.\(field.key)")
                        .padding(.trailing, 16)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("you.row.\(field.key)")
            }
        }
    }

    // MARK: - Forget

    @ViewBuilder
    private var forgetSection: some View {
        ThemedSectionHeader(title: "Forget")
        ThemedPanel {
            VStack(alignment: .leading, spacing: 0) {
                Button("Reset derived insights") { confirmReset = true }
                    .accessibilityIdentifier("you.forget.insights")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                ThemedRowDivider()
                Button("Erase chat history") { confirmWipe = true }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("you.forget.chat")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
        Text("Excluding a field above stops future use immediately; past replies already sent can't be recalled.")
            .font(Theme.font(12, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    // MARK: - Correction sheet

    @ViewBuilder
    private var correctionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your text replaces what the coach learned for this field. It wins over future re-derivation.")
                    .font(Theme.font(14, .regular, relativeTo: .body))
                    .foregroundStyle(Theme.secondary)
                TextField("Corrected text", text: $correctionDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("you.correct.field")
                if let error = viewModel.errorMessage {
                    ThemedErrorText(message: error, accessibilityIdentifier: "you.correct.error")
                }
                Spacer()
                Button("Save correction") {
                    if let key = editingKey {
                        viewModel.pinCorrection(correctionDraft, forKey: key)
                        if viewModel.errorMessage == nil {
                            editingKey = nil
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("you.correct.save")
                Button("Cancel", role: .cancel) { editingKey = nil }
                    .accessibilityIdentifier("you.correct.cancel")
            }
            .padding(20)
            .navigationTitle("Correct field")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("you.correct.sheet")
        }
    }
}

