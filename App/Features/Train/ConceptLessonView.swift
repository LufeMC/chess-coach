//
//  ConceptLessonView.swift
//  ChessCoach
//

import SwiftUI

/// The lesson, shown once, before the concept is ever exercised.
///
/// ## Why this screen exists at all
///
/// A tactic can be handed to someone cold: the position contains everything
/// needed to solve it, and failing teaches them to look harder. An opening, an
/// endgame technique and a positional idea are not like that — they are
/// knowledge. Showing somebody the Lucena position and marking them wrong
/// teaches nothing, because there was nothing in the position to work it out
/// from. They had either been told or they had not.
///
/// So this arrives before the exercise, exactly once per concept. Everything
/// after is practice.
///
/// ## Three parts, not a paragraph
///
/// *What it is*, *why it matters*, *what to look for* answer three different
/// questions, and a reader skimming for the third should not have to read the
/// first two to find it. The cue is last and stressed because it is the only
/// part that survives to the next game — and it is repeated verbatim in the
/// banner after the exercise, so the two halves of the idea are said the same
/// way both times.
struct ConceptLessonView: View {

    let concept: TrainingConcept
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    section("The idea", concept.teaching.idea)
                    section("Why it matters", concept.teaching.why)
                    cue
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            Button("Try it") { onStart() }
                .buttonStyle(.primaryAction)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(concept.family.label.uppercased())
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text(concept.title)
                .typeRole(.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
            Text(body)
                .typeRole(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cue gets the card, because it is the part meant to be remembered.
    private var cue: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to look for")
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(Palette.accent.dynamic)
            Text(concept.teaching.lookFor)
                .typeRole(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Palette.accentWash.dynamic)
        )
    }
}
