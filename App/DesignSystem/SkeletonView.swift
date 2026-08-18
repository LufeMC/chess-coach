//
//  SkeletonView.swift
//  ChessCoach
//
//  Design system — Loading.
//

import SwiftUI

/// A grey rounded rectangle standing in for content that has not arrived.
///
/// It takes the geometry it replaces because **zero layout shift is the entire
/// point**. A skeleton whose height guesses wrong is worse than a spinner: the
/// spinner at least never promised the content would land where it did. So the
/// API is deliberately geometry-first — you cannot construct one without saying
/// how tall the real thing is.
struct SkeletonView: View {
    var width: CGFloat? = nil
    let height: CGFloat
    var cornerRadius: CGFloat = CornerRadius.chip
    /// A slow sheen. Off by default: it is decoration, and a screen full of
    /// them shimmering out of phase is a light show, not a loading state.
    var shimmer: Bool = false

    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.skeleton.dynamic)
            .frame(width: width, height: height)
            .overlay {
                if shimmer {
                    sheen
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    private var sheen: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, Palette.skeleton.dynamic, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.6)
            .offset(x: phase * proxy.size.width * 1.6)
            .task {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}

/// Whether a skeleton is worth showing yet.
///
/// Under roughly 200ms a placeholder is a flash the user reads as a glitch —
/// the content was never really absent, the screen just blinked. Extracted from
/// the modifier so the threshold is one testable number rather than a magic
/// `sleep` buried in a view.
enum SkeletonPolicy {

    /// Loads faster than this show nothing at all.
    static let minimumVisibleDelay: Duration = .milliseconds(200)

    static func shouldShow(isLoading: Bool, elapsed: Duration) -> Bool {
        isLoading && elapsed >= minimumVisibleDelay
    }
}

private struct SkeletonModifier<Placeholder: View>: ViewModifier {
    let isLoading: Bool
    @ViewBuilder let placeholder: () -> Placeholder

    /// Separate from `isLoading` so the 200ms gate can open without the caller
    /// knowing it exists.
    @State private var passedDelay = false

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(showsSkeleton ? 0 : 1)
                // The real content stays in the layout at zero opacity, which
                // is the cheapest possible guarantee that nothing moves when it
                // arrives — the skeleton is measured against the thing itself.
                .accessibilityHidden(showsSkeleton)
            if showsSkeleton {
                placeholder()
                    .transition(.opacity)
            }
        }
        .animation(Motion.crossfade, value: showsSkeleton)
        .task(id: isLoading) {
            guard isLoading else {
                passedDelay = false
                return
            }
            try? await Task.sleep(for: SkeletonPolicy.minimumVisibleDelay)
            guard !Task.isCancelled else { return }
            passedDelay = true
        }
    }

    private var showsSkeleton: Bool { isLoading && passedDelay }
}

extension View {

    /// Replaces this view with `placeholder` while `isLoading`, after a ~200ms
    /// grace period.
    ///
    /// The real view keeps its place in the layout at zero opacity, so the
    /// placeholder is laid out against the geometry it is standing in for
    /// rather than a guess at it.
    func skeleton(
        if isLoading: Bool,
        @ViewBuilder placeholder: @escaping () -> some View
    ) -> some View {
        modifier(SkeletonModifier(isLoading: isLoading, placeholder: placeholder))
    }

    /// The common case: a plain bar matching this view's own height.
    func skeleton(if isLoading: Bool, height: CGFloat, width: CGFloat? = nil) -> some View {
        skeleton(if: isLoading) {
            SkeletonView(width: width, height: height)
        }
    }
}
