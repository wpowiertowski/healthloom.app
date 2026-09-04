// PromptEditorView.swift
//
// WP-26 (implementation-plan.md): the coach prompt editor, reached from
// Settings. Edits the base prompt (live token estimate), saves to the
// append-only version history, resets to the shipped default, restores any
// history entry, diffs the working copy against the default, and previews
// the exact effective prompt -- the working copy plus the safety suffix,
// rendered in a locked section the editor cannot touch (D10).

import CoachKit
import SwiftUI

struct PromptEditorView: View {
    @State private var viewModel: PromptEditorViewModel

    init(viewModel: PromptEditorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ThemedScreen(title: "Coach Prompt", chrome: .pushed) {
            Text("Tune how the coach speaks. The safety section at the bottom is always appended automatically and can't be edited.")
                .font(Theme.font(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .accessibilityIdentifier("prompt.blurb")

            editorSection
            previewSection
            diffSection
            historySection
        }
        .onAppear { viewModel.load() }
        .accessibilityIdentifier("prompt.screen")
    }

    // MARK: - Editor

    private var editorSection: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Base prompt")
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("~\(viewModel.estimatedTokens) tokens")
                        .font(Theme.font(12, .regular, relativeTo: .caption))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("prompt.tokens")
                }
                TextEditor(text: $viewModel.baseText)
                    .font(Theme.font(13, .regular, relativeTo: .footnote))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                    .accessibilityIdentifier("prompt.editor")
                Text("Leading/trailing whitespace is trimmed on save.")
                    .font(Theme.font(11, .regular, relativeTo: .caption2))
                    .foregroundStyle(Theme.secondary)
                if let errorMessage = viewModel.errorMessage {
                    ThemedErrorText(message: errorMessage, accessibilityIdentifier: "prompt.error")
                }
                if let notice = viewModel.notice {
                    Text(notice)
                        .font(Theme.font(12, .regular, relativeTo: .caption))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("prompt.notice")
                }
                HStack {
                    Button("Save") { _ = viewModel.save() }
                        .disabled(!viewModel.hasUnsavedChanges)
                        .accessibilityIdentifier("prompt.save")
                    Button("Reset to default") { viewModel.resetToDefault() }
                        .disabled(!viewModel.canReset)
                        .accessibilityIdentifier("prompt.reset")
                }
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Preview

    private var previewSection: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview effective prompt")
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                Text(viewModel.previewBase)
                    .font(Theme.font(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("prompt.preview")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Locked safety suffix — appended automatically")
                        .font(Theme.font(11, .semibold, relativeTo: .caption2))
                        .foregroundStyle(Theme.accentDeep)
                    Text(SafetyLayer.text)
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("prompt.suffix")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentTint))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                // `.contain`: the section identifier must not override the
                // suffix text's own identifier (same collapse as
                // `chat.screen` without it).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("prompt.locked")
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Diff

    private var diffSection: some View {
        // One diff access per render (#12): the empty-state check and the
        // row list derive from the same value, not two table builds.
        let diff = viewModel.diffVsDefault
        return ThemedPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text("Changes vs shipped default")
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .padding(.bottom, 4)
                if diff.allSatisfy(\.isCommon) {
                    Text("No changes — matches the shipped default.")
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("prompt.diff.clean")
                } else {
                    // `.contain`: the group identifier must not override
                    // the rows the way a bare ForEach modifier would (#3).
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(diff.enumerated()), id: \.offset) { index, line in
                            diffRow(line)
                                .accessibilityIdentifier("prompt.diff.row.\(index)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("prompt.diff")
                }
            }
        }
        .padding(.top, 20)
    }

    private func diffRow(_ line: PromptEditorViewModel.DiffLine) -> some View {
        let (prefix, text, color): (String, String, Color) = switch line {
        case .common(let t): ("  ", t, Theme.secondary)
        case .added(let t): ("+ ", t, Theme.ink)
        case .removed(let t): ("− ", t, Theme.accentDeep)
        }
        return Text("\(prefix)\(text)")
            .font(Theme.font(12, .regular, relativeTo: .caption))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - History

    private var historySection: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Version history")
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                if viewModel.history.isEmpty {
                    Text("No edits yet — saves and resets appear here.")
                        .font(Theme.font(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("prompt.history.empty")
                } else {
                    ForEach(viewModel.history) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.body)
                                    .font(Theme.font(12, .regular, relativeTo: .caption))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                Text(snapshot.createdAt, style: .date)
                                    .font(Theme.font(11, .regular, relativeTo: .caption2))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Button("Restore") { viewModel.restore(snapshot) }
                                .font(Theme.font(12, .medium, relativeTo: .caption))
                                .accessibilityIdentifier("prompt.restore.\(snapshot.id)")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("prompt.history.\(snapshot.id)")
                    }
                }
            }
        }
        .padding(.top, 20)
    }
}
