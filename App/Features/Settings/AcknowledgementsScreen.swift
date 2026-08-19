//
//  AcknowledgementsScreen.swift
//  ChessCoach
//

import SwiftUI

/// Third-party notices.
///
/// Both licences here have a *notice-preservation* clause, and a LICENSE file
/// sitting in the repo does not satisfy it once the app is installed on someone
/// else's device — the notice has to travel with the binary. This screen is that
/// notice. It exists before distribution rather than after, because the day the
/// app first leaves this machine is a bad day to discover it is missing.
struct AcknowledgementsScreen: View {

    /// Where the corresponding source is published.
    ///
    /// GPL v3 requires that everyone who receives the app can get the source it
    /// was built from — TestFlight testers included — so this is not a courtesy
    /// link, it is the compliance mechanism. It has to keep pointing at source
    /// that actually corresponds to the shipped build.
    static let sourceRepository = URL(string: "https://github.com/LufeMC/chess-coach")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // ChessCoach's own licence comes first. The rest of this screen
                // is notices *owed to* other projects; this card is the app
                // stating its own terms, which is the thing GPL v3 obliges and
                // the thing a list of third-party notices does not cover.
                VStack(alignment: .leading, spacing: 6) {
                    Text("ChessCoach")
                        .typeRole(.headline)

                    Text("GNU GPL v3")
                        .typeRole(.label)

                    Text("This app is free software. You may use, study, share and modify it under the terms of the GNU General Public License, version 3 or later.")
                        .typeRole(.body, appliesForeground: false)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("""
                        ChessCoach embeds Stockfish, which is licensed under the \
                        GNU General Public License v3. Linking it into this app \
                        makes the combined program a derivative work, so \
                        ChessCoach is distributed under the same licence, and \
                        its complete corresponding source is published.

                        This program comes with ABSOLUTELY NO WARRANTY.
                        """)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    Link("Source code", destination: Self.sourceRepository)
                        .typeRole(.caption)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .elevation(.raised, cornerRadius: CornerRadius.card)

                ForEach(Acknowledgement.all) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.name)
                            .typeRole(.headline)

                        Text(entry.licenseName)
                            .typeRole(.label)

                        Text(entry.role)
                            .typeRole(.body, appliesForeground: false)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(entry.notice)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)

                        if let url = entry.source {
                            Link("Source", destination: url)
                                .typeRole(.caption)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .elevation(.raised, cornerRadius: CornerRadius.card)
                }
            }
            .padding()
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Acknowledgements")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One third-party component and the notice that must ship with it.
struct Acknowledgement: Identifiable {
    var id: String { name }
    var name: String
    var licenseName: String
    /// What it does here, in the user's terms rather than the build system's.
    var role: String
    var notice: String
    var source: URL?

    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "Stockfish",
            licenseName: "GNU GPL v3",
            role: "Plays every opponent and analyses every finished game.",
            notice: """
                Copyright (C) 2004-2025 The Stockfish developers.
                Stockfish is free software: you can redistribute it and/or \
                modify it under the terms of the GNU General Public License as \
                published by the Free Software Foundation, either version 3 of \
                the License, or (at your option) any later version. It is \
                distributed WITHOUT ANY WARRANTY; without even the implied \
                warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
                """,
            source: URL(string: "https://github.com/official-stockfish/Stockfish")
        ),
        Acknowledgement(
            name: "ChessKit",
            licenseName: "MIT",
            role: "Move generation, legality, and notation — the rules themselves.",
            notice: """
                Copyright (c) 2023 ChessKit. Permission is hereby granted, free \
                of charge, to any person obtaining a copy of this software and \
                associated documentation files to deal in the Software without \
                restriction. The above copyright notice and this permission \
                notice shall be included in all copies or substantial portions \
                of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT \
                WARRANTY OF ANY KIND.
                """,
            source: URL(string: "https://github.com/chesskit-app/chesskit-swift")
        ),
        Acknowledgement(
            name: "Lichess puzzle database",
            licenseName: "Creative Commons CC0",
            role: "The 120,000 puzzles in the training corpus.",
            notice: """
                Puzzles from the Lichess open database, dedicated to the public \
                domain under CC0 1.0. Lichess is free/libre open-source software.
                """,
            source: URL(string: "https://database.lichess.org/#puzzles")
        ),
        Acknowledgement(
            name: "Staunty and Cburnett piece sets",
            licenseName: "GNU GPL v2+ / CC BY-SA 3.0",
            role: "The pieces you move.",
            notice: """
                Staunty by sadsnake1 and Cburnett by Colin M.L. Burnett, from \
                the Lichess piece set collection.
                """,
            source: URL(string: "https://github.com/lichess-org/lila/tree/master/public/piece")
        ),
    ]
}

#Preview {
    NavigationStack { AcknowledgementsScreen() }
}
