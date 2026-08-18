import Foundation
import Testing

@testable import Database

@Suite("Puzzle theme bitmask")
struct PuzzleThemeTests {

    // MARK: - Wire-format contract
    //
    // These are not "tests" so much as a tripwire. The bit index of each theme
    // is the on-disk encoding shared with the offline PuzzlePrep tool, so
    // reordering or removing a case silently corrupts every already-built
    // puzzles.sqlite. Pinning representative indices makes that a build failure.

    @Test("Theme count is pinned — appending is fine, changing the count of existing cases is not")
    func themeCountIsPinned() {
        #expect(PuzzleTheme.allCases.count == 65)
    }

    @Test("Bit indices are pinned to the shared wire format")
    func bitIndicesArePinned() {
        #expect(PuzzleTheme.advancedPawn.bit == 0)
        #expect(PuzzleTheme.castling.bit == 9)
        #expect(PuzzleTheme.doubleCheck.bit == 20)
        #expect(PuzzleTheme.mate.bit == 35)
        #expect(PuzzleTheme.quietMove.bit == 50)
        #expect(PuzzleTheme.zugzwang.bit == 61)
        // The lo/hi split lands between these two.
        #expect(PuzzleTheme.mix.bit == 62)
        #expect(PuzzleTheme.playerGames.bit == 63)
        #expect(PuzzleTheme.puzzleDownloadInformation.bit == 64)
    }

    @Test("Every theme has a distinct bit equal to its declaration order")
    func bitsAreDenseAndUnique() {
        let bits = PuzzleTheme.allCases.map(\.bit)
        #expect(bits == Array(0..<PuzzleTheme.allCases.count))
        #expect(Set(bits).count == bits.count)
    }

    @Test("Themes fit the declared mask capacity")
    func themesFitCapacity() {
        #expect(PuzzleTheme.allCases.count <= ThemeMask.bitCapacity)
    }

    @Test("Raw values match the Lichess tag strings")
    func rawValuesAreLichessTags() {
        #expect(PuzzleTheme.mateIn2.tag == "mateIn2")
        #expect(PuzzleTheme.attackingF2F7.tag == "attackingF2F7")
        #expect(PuzzleTheme.xRayAttack.tag == "xRayAttack")
        #expect(PuzzleTheme(rawValue: "smotheredMate") == .smotheredMate)
    }

    // MARK: - Encode / decode round-trips

    @Test("Single themes round-trip through the mask")
    func singleThemeRoundTrip() {
        for theme in PuzzleTheme.allCases {
            let mask = theme.mask
            #expect(mask.contains(theme))
            #expect(mask.themes == [theme])
            #expect(ThemeMask(storedLow: mask.storedLow, storedHigh: mask.storedHigh) == mask)
        }
    }

    @Test("Every theme survives a full storage round-trip")
    func allThemesRoundTripThroughStorage() {
        let all = ThemeMask(PuzzleTheme.allCases)
        let restored = ThemeMask(storedLow: all.storedLow, storedHigh: all.storedHigh)
        #expect(restored == all)
        #expect(restored.themes == PuzzleTheme.allCases)
    }

    @Test("Stored columns are never negative")
    func storedValuesAreNonNegative() {
        // SQLite INTEGER is signed; the 63/10 split exists precisely so neither
        // column can spill into the sign bit.
        let all = ThemeMask(PuzzleTheme.allCases)
        #expect(all.storedLow >= 0)
        #expect(all.storedHigh >= 0)
    }

    @Test("The lo/hi boundary is handled exactly")
    func boundaryBitsSplitCorrectly() {
        let lastLow = ThemeMask(bit: ThemeMask.lowBitCount - 1)
        #expect(lastLow.storedHigh == 0)
        #expect(lastLow.storedLow != 0)

        let firstHigh = ThemeMask(bit: ThemeMask.lowBitCount)
        #expect(firstHigh.storedLow == 0)
        #expect(firstHigh.storedHigh == 1)

        let both = lastLow.union(firstHigh)
        #expect(both.contains(bit: ThemeMask.lowBitCount - 1))
        #expect(both.contains(bit: ThemeMask.lowBitCount))
        #expect(ThemeMask(storedLow: both.storedLow, storedHigh: both.storedHigh) == both)
    }

    @Test("Mixed masks spanning both halves round-trip")
    func mixedMaskRoundTrip() {
        let themes: [PuzzleTheme] = [.fork, .mateIn2, .zugzwang, .mix, .puzzleDownloadInformation]
        let mask = ThemeMask(themes)
        let restored = ThemeMask(storedLow: mask.storedLow, storedHigh: mask.storedHigh)
        #expect(restored.themes == themes.sorted { $0.bit < $1.bit })
    }

    @Test("Tag lists encode and report unknown tags")
    func tagListEncoding() {
        let (mask, unknown) = PuzzleTheme.encode(tagList: "mateIn2 fork short")
        #expect(mask.themes == [.fork, .mateIn2, .short].sorted { $0.bit < $1.bit })
        #expect(unknown.isEmpty)

        let (partial, missing) = PuzzleTheme.encode(tagList: "fork someNewLichessTheme")
        #expect(partial.themes == [.fork])
        #expect(missing == ["someNewLichessTheme"])
    }

    // MARK: - Set semantics

    @Test("Intersection detects any-of matches")
    func intersects() {
        let puzzle = ThemeMask([.fork, .mateIn2, .short])
        #expect(puzzle.intersects(ThemeMask([.fork])))
        #expect(puzzle.intersects(ThemeMask([.pin, .mateIn2])))
        #expect(!puzzle.intersects(ThemeMask([.pin, .skewer])))
        #expect(!puzzle.intersects(.empty))
    }

    @Test("Insert and remove are inverses")
    func insertRemove() {
        var mask = ThemeMask.empty
        #expect(mask.isEmpty)
        mask.insert(.fork)
        mask.insert(.playerGames)
        #expect(mask.contains(.fork))
        #expect(mask.contains(.playerGames))
        mask.remove(.fork)
        #expect(!mask.contains(.fork))
        #expect(mask.contains(.playerGames))
        mask.remove(.playerGames)
        #expect(mask.isEmpty)
    }

    @Test("Bits set by a newer encoder are ignored, not fatal")
    func unknownBitsAreIgnored() {
        // A puzzles.sqlite built by a future tool may carry themes this build
        // has no case for. Those must be skipped silently.
        let futureBit = ThemeMask.bitCapacity - 1
        var mask = ThemeMask([.fork])
        mask.insert(bit: futureBit)
        #expect(mask.themes == [.fork])
        #expect(mask.contains(bit: futureBit))
        #expect(PuzzleTheme.theme(at: futureBit) == nil)
    }

    @Test("Array literals build masks")
    func arrayLiteral() {
        let mask: ThemeMask = [.fork, .pin]
        #expect(mask == ThemeMask([.fork, .pin]))
    }
}
