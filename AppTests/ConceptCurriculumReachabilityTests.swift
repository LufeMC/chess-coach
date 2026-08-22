//
//  ConceptCurriculumReachabilityTests.swift
//  ChessCoachTests
//

import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The one rule that binds the ladder to the catalogue: **if the curriculum is
/// asking the user to demonstrate a skill, the thing that teaches that skill has
/// to be reachable.**
///
/// The two halves of the app disagreed about what "available" meant, and had no
/// reason to notice. A rung is a counter advanced by met skills and seeded from
/// a fused playing-scale estimate; a concept unlocks off the Glicko puzzle
/// rating, which is a different scale produced by a different measurement. So
/// `r3.rookEndings` could gate a rung-3 user on two drills the catalogue would
/// not show them until 1400 — a ladder row that could not tick, driving a weekly
/// micro-goal nothing in the app could move.
///
/// These tests fail on that behaviour, and on the next version of it: adding a
/// drill gate without naming its teacher trips ``everyDrillGateNamesItsTeacher``,
/// and giving a named teacher a rating floor the rung cannot reach trips
/// ``everyTeacherIsReachableOnTheRungThatAsksForIt``.
@Suite("Curriculum and concept catalogue agree")
struct ConceptCurriculumReachabilityTests {

    /// A rating far below every floor in the catalogue, so the only thing that
    /// can make a concept available is the curriculum having asked for it.
    private let farBelowEveryFloor = 0

    // MARK: - The two catalogues agree

    @Test("Every teacher the curriculum names is a real concept")
    func everyTeacherNamesARealConcept() {
        for (skillID, conceptIDs) in Curriculum.conceptTeachers {
            for id in conceptIDs {
                #expect(
                    TrainingConcept.concept(id: id) != nil,
                    "\(skillID) names \(id), which is not in the catalogue"
                )
            }
        }
    }

    /// The drift guard in the direction that actually bites.
    ///
    /// A drill streak has exactly one writer — the drill screen — and that
    /// screen is reached only as a concept's exercise. So a criterion gating on
    /// one is a promise that the concept is reachable, and the table is where
    /// that promise is kept. Nothing else in the app would notice it missing:
    /// the row would simply read "not run yet" forever.
    @Test("Every drill the ladder gates on names the concept that teaches it")
    func everyDrillGateNamesItsTeacher() {
        for rung in Curriculum.default {
            for skill in rung.skills {
                for criterion in skill.criteria {
                    guard
                        let kind = EndgameDrillKind.allCases.first(
                            where: { $0.streakMetricKey == criterion.metricKey }
                        )
                    else { continue }

                    let teachers = (Curriculum.conceptTeachers[skill.id] ?? [])
                        .compactMap(TrainingConcept.concept(id:))
                    #expect(
                        teachers.contains { $0.exercise == .drill(kind) },
                        "\(skill.id) gates on the \(kind.rawValue) drill but names no concept that teaches it"
                    )
                }
            }
        }
    }

    /// The invariant, stated over the whole ladder rather than over the case
    /// that was reported.
    ///
    /// Rating zero because the rung is what is being tested: a user can arrive
    /// on any rung with any puzzle rating, since calibration fuses a game
    /// estimate with a puzzle estimate that are free to disagree by hundreds of
    /// points, and afterwards the two move independently.
    @Test("Everything a rung asks for is reachable on that rung at any rating")
    func everyTeacherIsReachableOnTheRungThatAsksForIt() {
        for rung in Curriculum.default {
            let servable = Set(
                TrainingConcept.available(atRating: farBelowEveryFloor, rung: rung.id).map(\.id)
            )
            // Unlocked, and actually served: one slot per set, and the ladder's
            // asks accumulate down the rungs, so a rung-4 user is owed five
            // endgames. All of them have to arrive inside a fortnight of sets or
            // "reachable" is a technicality.
            let served = Set(servedConcepts(rating: farBelowEveryFloor, rung: rung.id, sets: 14))

            for skill in rung.skills {
                for id in Curriculum.conceptTeachers[skill.id] ?? [] {
                    #expect(
                        servable.contains(id),
                        "rung \(rung.id) gates on \(skill.id) but would not serve \(id)"
                    )
                    #expect(
                        served.contains(id),
                        "rung \(rung.id) gates on \(skill.id); \(id) never came up in 14 sets"
                    )
                }
            }
        }
    }

    // MARK: - The reported case

    /// Rung 3 with a puzzle rating of 1050: the calibration outcome the audit
    /// worked through, and the one the old code could not train.
    @Test("A rung-3 user below 1400 is served the rook endings")
    func rookEndingsReachALowRatedRung3User() {
        let available = Set(TrainingConcept.available(atRating: 1050, rung: 3).map(\.id))
        #expect(available.contains("endgame.lucena"))
        #expect(available.contains("endgame.philidor"))

        // Available is not the same as served: the slot holds one concept and
        // eighteen things want it. Both rook endings have to actually arrive,
        // and inside a number of sets a user would sit through.
        let served = Set(servedConcepts(rating: 1050, rung: 3, sets: 12))
        #expect(served.contains("endgame.lucena"))
        #expect(served.contains("endgame.philidor"))
    }

    /// The other side of the same rule, and the reason it is not simply "unlock
    /// everything": a floor the ladder has not overridden still holds.
    @Test("A rung the ladder has not reached keeps its rating floors")
    func unaskedConceptsKeepTheirFloors() {
        let available = Set(TrainingConcept.available(atRating: 1050, rung: 3).map(\.id))
        // Rung 3 asks for the rook endings and says nothing about these, so the
        // catalogue's own sequencing is left in charge of them.
        #expect(available.contains("positional.worstPiece") == false, "floor 1300")
        #expect(available.contains("opening.ruyLopez") == false, "floor 1200")
        #expect(available.contains("endgame.kbbk") == false, "floor 1200, gated by nothing")
    }

    @Test("A rung-1 user is not served rung-3 content early")
    func rungOneIsNotServedRookEndings() {
        let available = Set(TrainingConcept.available(atRating: 900, rung: 1).map(\.id))
        #expect(available.contains("endgame.lucena") == false)
        #expect(available.contains("endgame.philidor") == false)

        let served = Set(servedConcepts(rating: 900, rung: 1, sets: 12))
        #expect(served.contains("endgame.lucena") == false)
        #expect(served.contains("endgame.philidor") == false)
        // And what rung 1 *does* ask for arrives.
        #expect(served.contains("endgame.kqk"))
        #expect(served.contains("endgame.krk"))
    }

    // MARK: - How the slot spends itself

    /// A blocked ladder row beats a lesson nobody asked for, but not twice in a
    /// row: rung 3 owes five endgames, and five endgame sets running is the week
    /// the user stops opening the app.
    @Test("The ladder's asks come first, but the set still changes subject")
    func owedConceptsAlternateWithTheRotation() {
        let served = servedConcepts(rating: 1050, rung: 3, sets: 8)
        let families = served.compactMap { TrainingConcept.concept(id: $0)?.family }

        #expect(families.first == .endgame, "the ladder is waiting on an endgame")
        for (index, family) in families.enumerated() where index > 0 {
            #expect(family != families[index - 1], "two \(family) sets in a row")
        }
    }

    /// A concept already taught stops jumping the queue, or the slot would spend
    /// itself on the same lesson forever and nothing else would ever be taught.
    @Test("Teaching an owed concept releases the slot")
    func taughtOwedConceptsStopJumpingTheQueue() throws {
        var states: [String: ConceptScheduler.State] = [:]
        for id in Curriculum.requiredConcepts(throughRung: 3) {
            states[id] = ConceptScheduler.State(id: id, isIntroduced: true, timesSeen: 3)
        }

        let selection = try #require(
            ConceptScheduler.next(rating: 1050, rung: 3, states: states)
        )
        #expect(
            Curriculum.requiredConcepts(throughRung: 3).contains(selection.concept.id) == false,
            "an untaught concept should have the slot now"
        )
        #expect(selection.teachFirst)
    }

    // MARK: - Helpers

    /// Runs the scheduler for `sets` sessions, teaching whatever it serves.
    ///
    /// Mirrors what the app does between sets: the concept is marked introduced
    /// when its lesson is read, and the family it belonged to becomes the next
    /// set's `lastFamily`.
    private func servedConcepts(rating: Int, rung: Int, sets: Int) -> [String] {
        var states: [String: ConceptScheduler.State] = [:]
        var lastFamily: TrainingConcept.Family?
        var served: [String] = []

        for index in 0..<sets {
            guard
                let selection = ConceptScheduler.next(
                    rating: rating,
                    rung: rung,
                    states: states,
                    lastFamily: lastFamily
                )
            else { break }

            let concept = selection.concept
            served.append(concept.id)
            states[concept.id] = ConceptScheduler.State(
                id: concept.id,
                isIntroduced: true,
                timesSeen: (states[concept.id]?.timesSeen ?? 0) + 1,
                lastSeenAt: Date(timeIntervalSince1970: Double(index))
            )
            lastFamily = concept.family
        }

        return served
    }
}
