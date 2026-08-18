import SwiftUI

// Screens whose full implementations land with their milestones. They exist now
// so navigation is real and the app builds and runs end to end.

struct TrainScreen: View {
    var body: some View {
        ContentUnavailableView {
            Label("Training", systemImage: "square.grid.3x3")
        } description: {
            Text("Puzzle queue and endgame drills arrive with the training loop.")
        }
        .navigationTitle("Train")
    }
}

struct ProfileScreen: View {
    var body: some View {
        ContentUnavailableView {
            Label("Profile", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text("Rating history, the curriculum ladder, and your rating leaks.")
        }
        .navigationTitle("Profile")
    }
}

struct GamesListScreen: View {
    var body: some View {
        ContentUnavailableView {
            Label("No games yet", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Play a game and it will appear here with its analysis.")
        }
        .navigationTitle("Games")
    }
}
