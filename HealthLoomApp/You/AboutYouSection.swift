// AboutYouSection.swift
//
// WP-61: the You tab's "About you" section -- goals, injuries and limits,
// activity preferences, in the user's own words. Saved through
// `KnowledgeStore.setAboutYou` (CoachKit/Knowledge/AboutYouField.swift):
// each entry becomes a profile field the coach reads with every reply.

import CoachKit
import SwiftUI

extension AboutYouField {
    var title: String {
        switch self {
        case .goals: "Goals"
        case .injuries: "Injuries and limits"
        case .activityPreferences: "Activity preferences"
        }
    }

    var placeholder: String {
        switch self {
        case .goals: "e.g. Half marathon in May"
        case .injuries: "e.g. Sore left knee on downhills"
        case .activityPreferences: "e.g. Rowing and cycling, mornings"
        }
    }
}

struct AboutYouSection: View {
    @Binding var drafts: [AboutYouField: String]
    /// What's stored, to tell whether Save has anything to do.
    let saved: [AboutYouField: String]
    let onSave: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasChanges: Bool {
        AboutYouField.allCases.contains { field in
            (drafts[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != (saved[field] ?? "")
        }
    }

    var body: some View {
        ThemedSectionHeader(title: "About you")
        Text("Tell the coach what your data can't. It reads these with every reply.")
            .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
        ThemedPanel {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(AboutYouField.allCases.enumerated()), id: \.element) { index, field in
                    if index > 0 { ThemedRowDivider() }
                    entry(for: field)
                }
            }
        }
        // One line beside Save when it fits; stacked at large sizes.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                limitNote
                Spacer(minLength: 8)
                saveButton
            }
            VStack(alignment: .leading, spacing: 4) {
                limitNote.fixedSize(horizontal: false, vertical: true)
                saveButton
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var limitNote: some View {
        Text("Up to \(AboutYouField.maxLength) characters each. Clear a field to remove it.")
            .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
            .foregroundStyle(Theme.secondary)
    }

    private var saveButton: some View {
        Button("Save", action: onSave)
            .font(Theme.font(Theme.Step.body, .semibold, relativeTo: .body))
            .foregroundStyle(hasChanges ? Theme.accent : Theme.tertiary)
            .disabled(!hasChanges)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("you.about.save")
    }

    private func entry(for field: AboutYouField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title)
                .font(Theme.font(Theme.Step.caption, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.ink)
            // A placeholder doesn't wrap: at accessibility sizes the example
            // moves out of the field into a line that can.
            if dynamicTypeSize.isAccessibilitySize {
                Text(field.placeholder)
                    .font(Theme.font(Theme.Step.caption, .regular, relativeTo: .caption))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(
                field.title,
                text: Binding(
                    get: { drafts[field] ?? "" },
                    set: { drafts[field] = String($0.prefix(AboutYouField.maxLength)) }
                ),
                // Tertiary is the palette's placeholder colour (clears 4.6:1);
                // the system prompt grey doesn't.
                prompt: Text(dynamicTypeSize.isAccessibilitySize ? "Type here" : field.placeholder)
                    .foregroundStyle(Theme.tertiary),
                axis: .vertical
            )
            // At least two lines (a vertical field reserves its minimum).
            // The You screen's hit-region audit (test plan §6) measures the
            // text view itself, not a frame around it: one line (17 pt)
            // fails it, two lines (33 pt) pass.
            .lineLimit(2...5)
            .font(Theme.font(Theme.Step.body, .regular, relativeTo: .body))
            .foregroundStyle(Theme.ink)
            .accessibilityLabel(field.title)
            .accessibilityIdentifier("you.about.\(field.rawValue)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
