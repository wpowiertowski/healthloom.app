// YouView.swift
//
// WP-30 (implementation-plan.md): the You tab — knowledge transparency.
// Three sections over the persisted `KnowledgeProfile`:
//
//   - Profile: every field (display text, source, as-of) with its AI-context
//     toggle. Clinical fields carry a "Clinical" badge and start excluded
//     (D8); correction-pinned fields carry a "Your correction" badge.
//     WP-41: one card per fact, not two stacked halves. The per-row
//     "Use for AI replies" label is gone -- it was identical on every
//     card, so it carried no per-row information while reading as loud
//     as the fact itself; it is stated once under the section header and
//     survives for VoiceOver as the toggle's accessibility label.
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
    /// Drives the one-line/stacked switch in each fact card (see below).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(viewModel: YouViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ThemedScreen(title: "You") {
            profileSection
            forgetSection
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
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
        // Said once, instead of six times. This also says what the toggle
        // *does*, which the repeated control label never did.
        // Flush with the section header above it. `ThemedScreen` already
        // owns the 22pt gutter, so any extra horizontal padding here reads
        // as a stray indent against every header on the screen.
        Text("Switch a fact off to stop the coach using it in replies.")
            .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
        if viewModel.fields.isEmpty {
            ThemedPanel {
                Text("Nothing here yet. Chat with the coach and your profile will appear.")
                    .font(Theme.font(Theme.Step.body, .regular, relativeTo: .body))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("you.empty")
            }
        } else {
            ForEach(viewModel.fields, id: \.key) { field in
                ThemedPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(field.displayText)
                            .font(Theme.font(Theme.Step.body, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        // Metadata and controls share one line. At
                        // accessibility sizes they stack: the badges and
                        // the two controls cannot hold a single row once
                        // the text doubles in size.
                        if dynamicTypeSize.isAccessibilitySize {
                            metadata(for: field)
                            controls(for: field)
                        } else {
                            HStack(spacing: 8) {
                                metadata(for: field)
                                Spacer(minLength: 8)
                                controls(for: field)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("you.row.\(field.key)")
            }
        }
    }

    /// Source, as-of date and any badges — the fact's provenance.
    @ViewBuilder
    private func metadata(for field: ProfileField) -> some View {
        let isCorrection = field.source == KnowledgeStore.correctionSourceLabel
        HStack(spacing: 6) {
            // D16.3: a source-and-timestamp line is an instrument reading.
            //
            // A corrected field drops its source here: the badge beside it
            // already says "Your correction", and printing the same fact
            // twice cost the row so much width that the date truncated away
            // ("User correction · S…"). The badge keeps the provenance; the
            // line keeps the date.
            Text(isCorrection
                 ? field.asOf.formatted(date: .abbreviated, time: .omitted)
                 : "\(field.source) · \(field.asOf.formatted(date: .abbreviated, time: .omitted))")
                .font(Theme.mono(Theme.Step.micro, .regular, relativeTo: .caption))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if field.isClinical {
                ThemedBadge(
                    text: "Clinical",
                    style: .accent,
                    accessibilityIdentifier: "you.clinical.\(field.key)"
                )
            }
            if isCorrection {
                ThemedBadge(
                    text: "Your correction",
                    accessibilityIdentifier: "you.correction.\(field.key)"
                )
            }
        }
    }

    /// The fact's two controls. Both keep a 44 pt target (the You screen
    /// runs a `.hitRegion` accessibility audit, test-plan §6) even though
    /// the switch and the label are visually smaller than that.
    @ViewBuilder
    private func controls(for field: ProfileField) -> some View {
        HStack(spacing: 12) {
            Toggle(
                "Use for AI replies",
                isOn: Binding(
                    get: { !field.excludedFromAI },
                    set: { viewModel.setExcluded(!$0, forKey: field.key) }
                )
            )
            .labelsHidden()
            .tint(Theme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            // The visible label is gone, so the control states its job here
            // or VoiceOver reads six unnamed switches.
            .accessibilityLabel("Use for AI replies")
            .accessibilityIdentifier("you.ai.\(field.key)")

            Button("Edit") {
                correctionDraft = field.displayText
                editingKey = field.key
            }
            .font(Theme.font(Theme.Step.caption, .medium, relativeTo: .caption))
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // Six buttons all labelled "Edit" are ambiguous out of context.
            .accessibilityLabel("Edit \(field.displayText)")
            .accessibilityIdentifier("you.edit.\(field.key)")
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
                // The only `.red` left in the app was here. The palette has
                // no red -- rust is its one functional colour (Theme.swift),
                // and ThemedChrome maps attention/error onto `accentDeep`.
                // The destructive signal is not lost: the confirmation
                // dialog's `role: .destructive` still renders system-red at
                // the moment the choice actually matters.
                Button("Erase chat history") { confirmWipe = true }
                    .foregroundStyle(Theme.accentDeep)
                    .accessibilityIdentifier("you.forget.chat")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
        Text("Excluding a field above stops future use immediately; past replies already sent can't be recalled.")
            .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // MARK: - Correction sheet

    @ViewBuilder
    private var correctionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your text replaces what the coach learned for this field. It wins over future re-derivation.")
                    .font(Theme.font(Theme.Step.body, .regular, relativeTo: .body))
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

