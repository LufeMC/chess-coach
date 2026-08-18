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
/// A winding-path level map was considered and rejected: it costs a screen and
/// a half to encode an ordering that "RUNG 1, RUNG 2" already carries, and it
/// makes a training tool look like a game.
struct CurriculumLadderSection: View {

    let state: CurriculumLadderState
    let onToggle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Curriculum")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 8)

            ForEach(state.rungs) { rung in
                RungSection(
                    rung: rung,
                    isExpanded: state.isExpanded(rung.id),
                    onToggle: { onToggle(rung.id) }
                )
                if rung.id != state.rungs.last?.id {
                    Divider()
                }
            }
        }
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
                    .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Eyebrow(text: "Rung \(rung.id)")
                        if rung.status == .locked {
                            ProfileChip(text: "LOCKED")
                        }
                        if rung.status == .completed {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(rung.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(rung.status == .locked ? .secondary : .primary)
                }

                Spacer(minLength: 8)

                Text(rung.completionFraction)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ratings \(rung.ratingBand.lowerBound)–\(rung.ratingBand.upperBound)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            ForEach(rung.skills) { skill in
                SkillRow(skill: skill)
            }

            if !rung.blockerMessages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rung.blockerMessages, id: \.self) { message in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                            Text(message)
                                .font(.footnote)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: skill.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.title)
                        .font(.subheadline)
                        .foregroundStyle(skill.isMet ? .secondary : .primary)
                    if skill.isRequired {
                        Text("REQUIRED")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.tertiary)
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
            Text("Not enough games yet — \(samplesNeeded) more to measure this")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let measurement = skill.measurement {
            Text(measurement)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if skill.isMet {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Met")
        } else {
            Circle()
                .strokeBorder(.quaternary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Not met")
        }
    }
}
