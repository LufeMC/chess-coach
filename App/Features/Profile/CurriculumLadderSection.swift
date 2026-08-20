//
//  CurriculumLadderSection.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// The four-rung curriculum as an accordion.
///
/// The wall problem this solves: four rungs × five skills is twenty rows, and a
/// screen that opens on twenty checkboxes tells a rung-1 player that they have
/// nineteen things wrong with them. Exactly one section is open — the rung they
/// are on — and the other three collapse to a header carrying a completion
/// fraction, so the ladder occupies roughly a third of a screen while still
/// reporting where every rung stands.
///
/// ## Why every sub-skill is named
///
/// The open rung lists its skills by their **measurable** names — "hanging
/// pieces under 1.0 per 100 moves", not "board vision" — because that is the
/// difference between a ladder that reads as competence and one that reads as
/// points. A user who can name what they are being measured on can go and
/// practise it; a user shown a percentage can only wait.
///
/// A winding-path level map was considered and rejected: it costs a screen and
/// a half to encode an ordering that "RUNG 1, RUNG 2" already carries, and it
/// makes a training tool look like a game.
struct CurriculumLadderSection: View {

    let state: CurriculumLadderState
    let onToggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Curriculum", qualifier: qualifier)
                .padding(.bottom, 4)

            ForEach(state.rungs) { rung in
                RungSection(
                    rung: rung,
                    isExpanded: state.isExpanded(rung.id),
                    onToggle: { onToggle(rung.id) }
                )
                if rung.id != state.rungs.last?.id {
                    Rectangle()
                        .fill(Palette.hairline.dynamic)
                        .frame(height: 1)
                }
            }
        }
    }

    /// `RUNG 2 OF 4`, right-aligned and dimmer — the same small-caps style as
    /// the header it sits beside.
    private var qualifier: String? {
        guard let current = state.rungs.first(where: { $0.status == .current }) else { return nil }
        return "Rung \(current.id) of \(state.rungs.count)"
    }
}

private struct RungSection: View {

    let rung: LadderRungRow
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                expandedBody
                    .padding(.top, 4)
                    .padding(.bottom, 14)
            }
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Eyebrow(text: "Rung \(rung.id)")
                        if rung.status == .locked {
                            ProfileChip(text: "Locked")
                        }
                        if rung.status == .completed {
                            Image(systemName: "checkmark.circle.fill")
                                .typeRole(.caption, appliesForeground: false)
                                .foregroundStyle(.primary)
                        }
                    }
                    Text(rung.title)
                        .typeRole(.headline, appliesForeground: false)
                        // Locked rungs go quiet by weight, not by dimming the
                        // whole row — a row at reduced opacity reads as broken
                        // rendering rather than as "not yet".
                        .foregroundStyle(rung.status == .locked ? .secondary : .primary)
                }

                Spacer(minLength: 8)

                Text(rung.completionFraction)
                    .typeRole(.caption, monospacedDigits: true)

                Image(systemName: "chevron.right")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ratings \(rung.ratingBand.lowerBound)–\(rung.ratingBand.upperBound)")
                .typeRole(.label, monospacedDigits: true)

            ForEach(rung.skills) { skill in
                SkillRow(skill: skill)
            }

            if !rung.blockerMessages.isEmpty {
                // One wrapped line, not one row per blocker with an arrow
                // glyph in front of it. Three stacked arrows read as three
                // separate instructions to act on; they are three facts about
                // the same wait, and they belong in one sentence.
                Text(rung.blockerMessages.joined(separator: " · "))
                    .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

/// One skill.
///
/// Required and optional skills are marked apart because advancement needs all
/// the required ones plus whatever else lands: without the distinction a user
/// stares at an unmet optional row wondering why it is holding them up, when it
/// never was.
private struct SkillRow: View {

    let skill: LadderSkillRow

    var body: some View {
        // The per-skill category glyph that used to lead this row is gone. It
        // was a third status signal on a row that already has two — the tick on
        // the right and the weight of the title — and a column of small grey
        // symbols is most of what made this list feel like a spreadsheet.
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.title)
                        .typeRole(.body, appliesForeground: false)
                        // A met skill steps back to secondary rather than being
                        // struck through: a strikethrough reads as cancelled,
                        // which is the opposite of earned.
                        .foregroundStyle(skill.isMet ? .secondary : .primary)
                    // Tag the exception, not the rule. Most skills on a rung
                    // are required, so a "Required" badge on four rows in five
                    // is noise that makes the one optional row invisible —
                    // which is the only row the badge was ever meant to find.
                    if !skill.isRequired {
                        Text("Optional")
                            .typeRole(.label)
                    }
                }

                detail
            }

            Spacer(minLength: 8)

            indicator
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let samplesNeeded = skill.samplesNeeded {
            // Honest empty state, not a zero. A zero blunder rate and an
            // unmeasured blunder rate look identical, and one of them is a lie.
            //
            // Said in four words rather than eleven: the long form wrapped to
            // two lines under every unmeasured skill, which on a fresh account
            // is most of them, and repeating a sentence that long down a list
            // turns an honest disclosure into clutter.
            Text(samplesNeeded == 1 ? "Needs 1 more game" : "Needs \(samplesNeeded) more games")
                .typeRole(.label, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let measurement = skill.measurement {
            Text(measurement)
                .typeRole(.caption, monospacedDigits: true)
        }
    }

    /// Filled when met, a grey outline when not.
    ///
    /// Ink rather than accent: the accent on this screen belongs to the leak
    /// the user is being asked to work on, and twenty accent-coloured ticks
    /// would outshout it while saying nothing to act on.
    @ViewBuilder
    private var indicator: some View {
        if skill.isMet {
            Image(systemName: "checkmark.circle.fill")
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.primary)
                .accessibilityLabel("Met")
        } else {
            Circle()
                .strokeBorder(Palette.hairlinePending.dynamic, lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Not met")
        }
    }
}
