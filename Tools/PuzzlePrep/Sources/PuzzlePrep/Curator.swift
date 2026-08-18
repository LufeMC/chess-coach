import Foundation

// MARK: - Deterministic PRNG

/// SplitMix64.
///
/// WHY NOT `Int.random(in:)`: the system RNG is seeded per process, so two runs
/// over the same dump would emit two different 120k subsets. That matters more
/// than it looks — the built database is a versioned build artifact. If a
/// rebuild silently reshuffles which puzzles exist, then puzzle IDs stored in
/// user progress, test fixtures pinned to specific puzzles, and any bug report
/// referencing "puzzle X at rating Y" all rot. A fixed seed makes the dump the
/// single input: same dump in, byte-identical selection out.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Array {
    /// Fisher-Yates with an explicit generator, so shuffles are reproducible.
    mutating func deterministicShuffle(using rng: inout SplitMix64) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            if i != j { swapAt(i, j) }
        }
    }
}

// MARK: - Candidate

/// The minimum a puzzle needs to carry through curation.
///
/// WHY SO SMALL: curation happens over every quality-filtered row (~2.26M), and
/// this struct is the only thing held in memory between the two streaming
/// passes. Storing FEN/moves/URL here would cost hundreds of megabytes for text
/// that pass 2 re-reads from the dump anyway; storing 16 bytes costs ~36 MB.
struct Candidate {
    /// Index of the row among data rows (header excluded). Stable across passes
    /// because both passes read the same file in the same order — this is how
    /// pass 2 knows which rows to materialise.
    var rowIndex: UInt32
    var rating: UInt16
    var band: UInt8
    var maskLo: UInt64
    var maskHi: UInt64
}

// MARK: - Rating bands

enum Bands {
    static let minRating = 600
    static let maxRating = 2400 // exclusive
    static let width = 100
    static let count = (maxRating - minRating) / width // 18

    /// Band index, or nil if the puzzle sits outside the trained range.
    @inline(__always)
    static func index(forRating r: Int) -> Int? {
        guard r >= minRating, r < maxRating else { return nil }
        return (r - minRating) / width
    }

    static func label(_ i: Int) -> String {
        let lo = minRating + i * width
        return "\(lo)-\(lo + width - 1)"
    }
}

// MARK: - Curation

struct CurationResult {
    /// Selected row indices, ascending — pass 2 walks this with a cursor.
    var selectedRowIndices: [UInt32]
    var perBandCount: [Int]
    /// Theme bit -> number of selected puzzles carrying it.
    var perThemeCount: [Int]
    /// Theme bit -> number of *available* (quality-filtered, in-band) puzzles.
    var perThemeAvailable: [Int]
    /// Guaranteed themes that could not reach their minimum, with what they got.
    var themeShortfalls: [(theme: String, got: Int, wanted: Int, available: Int)]
    var candidatesInBandRange: Int
}

struct Curator {
    let targetCount: Int
    let perThemeMinimum: Int
    let seed: UInt64
    /// Bit indices of themes that carry a hard minimum.
    let guaranteedThemeBits: [Int]

    func curate(_ candidates: [Candidate]) -> CurationResult {
        var rng = SplitMix64(seed: seed)
        let themeCount = ThemeTable.ordering.count

        // ---- Group candidates by rating band -------------------------------
        // Candidates outside 600-2399 were already dropped by the caller, but
        // guard anyway so the band arrays are dense.
        var bandLists = [[Int]](repeating: [], count: Bands.count)
        for (i, c) in candidates.enumerated() {
            bandLists[Int(c.band)].append(i)
        }

        // Shuffling once up front is what makes every later "take the next one"
        // an unbiased random draw while still being reproducible: the greedy
        // passes below walk these lists in order and never re-randomise.
        for b in 0..<Bands.count {
            bandLists[b].deterministicShuffle(using: &rng)
        }

        var perThemeAvailable = [Int](repeating: 0, count: themeCount)
        for c in candidates {
            var lo = c.maskLo
            while lo != 0 {
                let bit = lo.trailingZeroBitCount
                perThemeAvailable[bit] += 1
                lo &= lo - 1
            }
            var hi = c.maskHi
            while hi != 0 {
                let bit = hi.trailingZeroBitCount + ThemeMask.lowWordBits
                if bit < themeCount { perThemeAvailable[bit] += 1 }
                hi &= hi - 1
            }
        }

        var selected = [Bool](repeating: false, count: candidates.count)
        var perBandCount = [Int](repeating: 0, count: Bands.count)
        var perThemeCount = [Int](repeating: 0, count: themeCount)
        var totalSelected = 0

        /// Marks a candidate selected and credits every theme it carries.
        /// Crediting *all* themes (not just the one we were shopping for) is
        /// what keeps the theme phase cheap: a puzzle tagged
        /// `fork hangingPiece crushing` pays down three minimums at once.
        func select(_ idx: Int) {
            guard !selected[idx] else { return }
            selected[idx] = true
            let c = candidates[idx]
            perBandCount[Int(c.band)] += 1
            totalSelected += 1
            var lo = c.maskLo
            while lo != 0 {
                perThemeCount[lo.trailingZeroBitCount] += 1
                lo &= lo - 1
            }
            var hi = c.maskHi
            while hi != 0 {
                let bit = hi.trailingZeroBitCount + ThemeMask.lowWordBits
                if bit < themeCount { perThemeCount[bit] += 1 }
                hi &= hi - 1
            }
        }

        // ---- Per-band quotas ------------------------------------------------
        let base = targetCount / Bands.count
        var quota = [Int](repeating: base, count: Bands.count)
        for i in 0..<(targetCount % Bands.count) { quota[i] += 1 }

        // ---- Phase 1: satisfy theme minimums --------------------------------
        //
        // Runs BEFORE the bulk fill, because a rare theme (underPromotion,
        // enPassant) is a tiny fraction of the pool: if the bulk fill ran first
        // it would consume the band quotas with common tactics and leave no
        // room to guarantee the rare ones.
        //
        // Themes are processed rarest-first so scarce themes get first refusal
        // on the puzzles that carry them, and each pick comes from whichever
        // band is currently furthest below quota — that is what keeps the
        // rating distribution flat even though this phase is theme-driven.
        var cursors = [[Int]](repeating: [Int](repeating: 0, count: Bands.count), count: themeCount)
        let orderedThemes = guaranteedThemeBits.sorted {
            // Rarest first; ties broken by bit index so the order is stable.
            (perThemeAvailable[$0], $0) < (perThemeAvailable[$1], $1)
        }

        for themeBit in orderedThemes {
            while perThemeCount[themeBit] < perThemeMinimum {
                // Pick the band furthest below its quota that still has an
                // unselected candidate carrying this theme.
                var bestBand = -1
                var bestHeadroom = Int.min
                var chosenIdx = -1
                for b in 0..<Bands.count {
                    // Advance this (theme, band) cursor to the next usable candidate.
                    var k = cursors[themeBit][b]
                    let list = bandLists[b]
                    while k < list.count {
                        let idx = list[k]
                        if !selected[idx] && candidateHasTheme(candidates[idx], themeBit) { break }
                        k += 1
                    }
                    cursors[themeBit][b] = k
                    guard k < list.count else { continue }
                    let headroom = quota[b] - perBandCount[b]
                    if headroom > bestHeadroom {
                        bestHeadroom = headroom
                        bestBand = b
                        chosenIdx = list[k]
                    }
                }
                guard bestBand >= 0, chosenIdx >= 0 else { break } // theme exhausted
                select(chosenIdx)
                cursors[themeBit][bestBand] += 1
            }
        }

        // ---- Phase 2: fill each band up to quota ----------------------------
        var fillCursor = [Int](repeating: 0, count: Bands.count)

        func takeNext(fromBand b: Int) -> Bool {
            let list = bandLists[b]
            var k = fillCursor[b]
            while k < list.count && selected[list[k]] { k += 1 }
            fillCursor[b] = k
            guard k < list.count else { return false }
            select(list[k])
            fillCursor[b] = k + 1
            return true
        }

        for b in 0..<Bands.count {
            while perBandCount[b] < quota[b] && totalSelected < targetCount {
                if !takeNext(fromBand: b) { break } // band exhausted: take what exists
            }
        }

        // ---- Phase 3: redistribute the shortfall ----------------------------
        // Bands that ran dry (or that phase 1 overfilled) leave the total under
        // target. Round-robin across the bands that still have candidates so
        // the make-up puzzles stay as evenly spread as the pool allows, rather
        // than dumping them all into one dense band.
        while totalSelected < targetCount {
            var progressed = false
            for b in 0..<Bands.count where totalSelected < targetCount {
                if takeNext(fromBand: b) { progressed = true }
            }
            if !progressed { break } // whole pool exhausted
        }

        // ---- Report shortfalls ----------------------------------------------
        var shortfalls: [(theme: String, got: Int, wanted: Int, available: Int)] = []
        for bit in guaranteedThemeBits where perThemeCount[bit] < perThemeMinimum {
            shortfalls.append((
                theme: ThemeTable.ordering[bit],
                got: perThemeCount[bit],
                wanted: perThemeMinimum,
                available: perThemeAvailable[bit]
            ))
        }
        shortfalls.sort { $0.got < $1.got }

        // Ascending row order lets pass 2 match rows with a single forward
        // cursor instead of a hash lookup per row.
        var chosen = [UInt32]()
        chosen.reserveCapacity(totalSelected)
        for (i, isSel) in selected.enumerated() where isSel {
            chosen.append(candidates[i].rowIndex)
        }
        chosen.sort()

        return CurationResult(
            selectedRowIndices: chosen,
            perBandCount: perBandCount,
            perThemeCount: perThemeCount,
            perThemeAvailable: perThemeAvailable,
            themeShortfalls: shortfalls,
            candidatesInBandRange: candidates.count
        )
    }

    @inline(__always)
    private func candidateHasTheme(_ c: Candidate, _ bit: Int) -> Bool {
        if bit < ThemeMask.lowWordBits {
            return c.maskLo & (1 << UInt64(bit)) != 0
        }
        return c.maskHi & (1 << UInt64(bit - ThemeMask.lowWordBits)) != 0
    }
}
