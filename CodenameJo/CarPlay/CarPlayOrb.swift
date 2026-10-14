import SwiftUI
import UIKit

/// The phone's mercury orb as a looping car-screen animation, rendered from `MercuryOrbScene`'s
/// own clock. `CPVoiceControlState` images max out at 150×150 points; each frame is ~350 KB.
@MainActor
enum CarPlayOrb {

    /// Two under `CPVoiceControlState`'s 150-point maximum, so nothing is rescaled.
    private static let boxSize: CGFloat = 148
    /// The bead. Sized against `glowRadius` rather than `VoiceOrb`'s much softer shadow —
    /// `136 ÷ 2 + 6 = 74`, exactly the half-box.
    private static let beadDiameter: CGFloat = 136
    /// A tight rim glow standing in for `VoiceOrb`'s shadow: it reads in sunlight and leaves room
    /// for a bigger bead inside 150 points.
    private static let glowRadius: CGFloat = 6
    /// Doubled by the ping-pong below, so the visible loop is 4 seconds — inside the template's
    /// documented 0.3–5s window.
    private static let forwardSpan: TimeInterval = 2.0
    /// Distinct renders: a memory number (~7 MB per sequence). The ping-pong re-references the same
    /// `UIImage`s rather than copying them.
    private static let uniqueFrames = 20

    /// The orb, animated, for a session state. `inCall` is not consulted; `muted` pushes the mood
    /// to `.muted`, as the phone does.
    static func animatedImage(
        state: SessionState,
        inCall: Bool,
        muted: Bool = false,
        style: UIUserInterfaceStyle
    ) -> UIImage? {
        let forward = (0..<uniqueFrames).compactMap { index -> UIImage? in
            render(
                state: state,
                inCall: inCall,
                muted: muted,
                style: style,
                // Deterministic from zero, so two states rendered a moment apart are the same
                // animation.
                at: forwardSpan * Double(index) / Double(uniqueFrames)
            )
        }
        guard forward.count == uniqueFrames else { return forward.first }

        // Ping-pong, because the bead's incommensurate sines can't loop within 5s. The endpoints
        // are dropped from the reverse leg so the turnaround frames aren't held twice.
        let frames = forward + forward.dropFirst().dropLast().reversed()
        return UIImage.animatedImage(with: frames, duration: forwardSpan * 2)
    }

    private static func render(
        state: SessionState,
        inCall: Bool,
        muted: Bool,
        style: UIUserInterfaceStyle,
        at t: TimeInterval
    ) -> UIImage? {
        // `mood` folds in `inCall && !muted`, so a muted call renders `.muted`, as on the phone.
        let beadMood = mood(state: state, inCall: inCall, muted: muted)
        // **The bead's own palette, not `Theme`'s** — see `OrbMood.tint`. The glow below
        // takes it too, so the halo on the car screen is the colour the metal actually is.
        let tint = beadMood.tint

        // `ImageRenderer` sees the orb's `SCNView` as an empty box, so SceneKit is snapshotted
        // directly. The stage overflow is cropped back: no budget for a halo.
        let stage = beadDiameter * MercuryOrbScene.stageScale
        guard let snapshot = MercuryOrbSnapshot.image(
            // The full mood, so the car gets each state's motion; a knock is an event, so a still
            // never carries one.
            mood: beadMood,
            tint: tint,
            at: t,
            side: stage,
            style: style
        ) else { return nil }

        let bead = Image(uiImage: snapshot)
            .resizable()
            .frame(width: stage, height: stage)
            .frame(width: beadDiameter, height: beadDiameter)
            .clipped()
            // Our own glow, not `VoiceOrb`'s — see `glowRadius`. Centred, with no `y`
            // offset, so the padding does not have to be lopsided to accommodate it.
            .shadow(color: tint.opacity(0.55), radius: glowRadius)
            .frame(width: boxSize, height: boxSize)
            // A head unit picks light or dark from the vehicle, not the phone.
            .environment(\.colorScheme, style == .dark ? .dark : .light)

        let renderer = ImageRenderer(content: bead)
        renderer.scale = 2
        // The car composites onto its own wallpaper; an opaque render would paste a white
        // or black square around the bead.
        renderer.isOpaque = false
        return renderer.uiImage
    }

    /// The car's read of the session, delegating to `VoiceOrb.mood`. `inCall` is not consulted.
    private static func mood(state: SessionState, inCall: Bool, muted: Bool) -> OrbMood {
        VoiceOrb.mood(state: state, muted: muted)
    }
}
