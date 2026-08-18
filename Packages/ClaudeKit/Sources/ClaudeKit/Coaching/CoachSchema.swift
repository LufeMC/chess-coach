//
//  CoachSchema.swift
//  ClaudeKit
//

import Foundation

/// The strict JSON schemas handed to `output_config.format`.
public enum CoachSchema {

    /// Schema for ``CoachResponse``.
    ///
    /// Note what the schema can and cannot do. It can force the *shape*: moves
    /// as discrete fields, limits on lengths, a closed habit enum. It cannot
    /// force the *content*: nothing here stops the model writing a plausible
    /// UCI string that isn't in the PV, or slipping "Nxe5" into a question.
    /// That is ``CoachVerifier``'s job, and the schema exists to make that job
    /// a small, mechanical one.
    public static func coachResponse(
        momentIDs: [String],
        habitIDs: [String] = CoachingVocabulary.habits.map(\.id)
    ) -> JSONValue {
        let moveRef = JSONSchema.object(
            [
                "san": JSONSchema.string(description: "Standard algebraic notation, copied exactly from the PV."),
                "uci": JSONSchema.string(
                    description: "Long algebraic / UCI notation, e.g. g1f3 or e7e8q. Must match the PV entry at this ply exactly.",
                    maxLength: 5,
                    minLength: 4
                ),
                "plyFromRoot": JSONSchema.integer(
                    description: "0 for the first move of the line, counting up. Lines always start at 0.",
                    minimum: 0
                )
            ],
            required: ["san", "uci", "plyFromRoot"]
        )

        func line(nullable: Bool, description: String) -> JSONValue {
            JSONSchema.object(
                [
                    "sourcePVIndex": JSONSchema.integer(
                        description: "Index into this moment's engineLines array that the moves were copied from.",
                        minimum: 0
                    ),
                    "moves": JSONSchema.array(
                        of: moveRef,
                        description: "An unbroken prefix of that PV, starting at its first move.",
                        minItems: 1,
                        maxItems: CoachRequest.Caps.maxPVPlies
                    )
                ],
                required: ["sourcePVIndex", "moves"],
                description: description,
                nullable: nullable
            )
        }

        let momentNote = JSONSchema.object(
            [
                "momentID": JSONSchema.string(
                    description: "The momentID being annotated.",
                    enumValues: momentIDs.isEmpty ? nil : momentIDs
                ),
                "question": JSONSchema.string(
                    description: """
                        One Socratic question the student could have asked themselves in this position. \
                        Contains NO move notation of any kind — no SAN, no UCI, no square names as moves.
                        """,
                    maxLength: CoachResponse.Limits.question
                ),
                "explanation": JSONSchema.string(
                    description: "Why the question matters here, tied to the moment's causeTag and stepTag.",
                    maxLength: CoachResponse.Limits.explanation
                ),
                "keyLine": line(nullable: false, description: "The line that answers the question."),
                "alternativeLine": line(nullable: true, description: "A second line, or null."),
                "causeAffirmed": JSONSchema.boolean(description: "False if the provided causeTag looks wrong."),
                "suggestedTag": JSONSchema.string(
                    description: "A better cause tag when causeAffirmed is false, otherwise null.",
                    enumValues: CoachingVocabulary.causeTags,
                    nullable: true
                )
            ],
            required: ["momentID", "question", "explanation", "keyLine", "alternativeLine", "causeAffirmed", "suggestedTag"]
        )

        return JSONSchema.object(
            [
                "gameNote": JSONSchema.object(
                    [
                        "headline": JSONSchema.string(maxLength: CoachResponse.Limits.headline),
                        "body": JSONSchema.string(maxLength: CoachResponse.Limits.body),
                        "tone": JSONSchema.string(enumValues: CoachResponse.GameNote.Tone.allCases.map(\.rawValue))
                    ],
                    required: ["headline", "body", "tone"]
                ),
                "momentNotes": JSONSchema.array(
                    of: momentNote,
                    description: "Exactly one note per provided moment, in the order given.",
                    maxItems: CoachRequest.Caps.maxMoments
                ),
                "weeklyFocusSuggestion": JSONSchema.object(
                    [
                        "habitID": JSONSchema.string(enumValues: habitIDs),
                        "rationale": JSONSchema.string(maxLength: CoachResponse.Limits.rationale)
                    ],
                    required: ["habitID", "rationale"]
                ),
                "flags": JSONSchema.object(
                    [
                        "disagreesWithCauseTag": JSONSchema.array(
                            of: JSONSchema.string(),
                            description: "momentIDs whose causeTag you dispute."
                        )
                    ],
                    required: ["disagreesWithCauseTag"]
                )
            ],
            required: ["gameNote", "momentNotes", "weeklyFocusSuggestion", "flags"]
        )
    }

    /// Schema for ``WeeklyFocusResponse``.
    public static func weeklyFocus(
        habitIDs: [String] = CoachingVocabulary.habits.map(\.id),
        metricIDs: [String] = CoachingVocabulary.habits.flatMap(\.metricIDs)
    ) -> JSONValue {
        JSONSchema.object(
            [
                "focusHabit": JSONSchema.string(
                    description: "Exactly one habit for the coming week.",
                    enumValues: habitIDs
                ),
                "whyNow": JSONSchema.string(
                    description: "Why this habit, this week, for this student.",
                    maxLength: WeeklyFocusResponse.Limits.whyNow
                ),
                "microGoal": JSONSchema.object(
                    [
                        "metricID": JSONSchema.string(
                            description: "A metric belonging to focusHabit.",
                            enumValues: metricIDs.isEmpty ? nil : Array(Set(metricIDs)).sorted()
                        ),
                        "target": JSONSchema.number(description: "Target value for that metric."),
                        "window": JSONSchema.string(
                            description: "Measurement window.",
                            enumValues: WeeklyFocusResponse.Window.allCases.map(\.rawValue)
                        )
                    ],
                    required: ["metricID", "target", "window"]
                ),
                "drillMix": JSONSchema.array(
                    of: JSONSchema.object(
                        [
                            "theme": JSONSchema.string(description: "Drill theme id."),
                            "count": JSONSchema.integer(description: "How many of this theme.", minimum: 1, maximum: 50)
                        ],
                        required: ["theme", "count"]
                    ),
                    minItems: 1,
                    maxItems: 6
                )
            ],
            required: ["focusHabit", "whyNow", "microGoal", "drillMix"]
        )
    }

}
