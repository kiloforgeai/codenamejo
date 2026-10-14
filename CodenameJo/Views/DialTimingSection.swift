#if DEBUG
import SwiftUI

/// The last dial's timing, on screen.
///
/// **On screen because the console cannot reach this measurement.** `RealtimeLog`
/// only prints, and reading a device's prints means
/// `xcrun devicectl device process launch --console` — a command that launches the
/// app itself, which is precisely the thing a Lock Screen press was supposed to do.
/// There is no way to attach a console to a launch you did not start, so the numbers
/// have to survive to be read afterwards.
///
/// The one readout kept from the old Hands-free engine section, and debug builds only
/// (#86). Snapshotted on appear rather than observed: both instruments are plain
/// statics written from libwebrtc's threads.
struct DialTimingSection: View {
    @State private var timing = DialTimingSnapshot()

    var body: some View {
        Section {
            timings
        } header: {
            SettingsRow.header("Last dial timing")
        }
        .onAppear { timing = DialTimingSnapshot.current() }
    }

    /// The two instruments, in the order the user experienced them: the launch legs
    /// `LaunchTiming` measured, then the dial legs `DialTiming` did, then the total
    /// that spans both.
    ///
    /// **Cold and warm are labelled rather than averaged.** A warm dial skips the
    /// process launch entirely, so the two are different measurements and comparing
    /// one against the other is how a change gets credited with a win it didn't earn.
    @ViewBuilder
    private var timings: some View {
        if timing.toDialMs == nil, timing.dialTotalMs == nil {
            note("Nothing recorded yet. Tap the orb, the Lock Screen control or the "
                 + "Action Button, let the call connect, then come back here.",
                 tint: Theme.textTertiary)
        } else {
            if let toTalk = timing.toTalkMs {
                row("Press → you could talk",
                    "\(LaunchTiming.format(toTalk))ms",
                    tint: toTalk <= 2_500 ? Theme.success : toTalk <= 4_000 ? Theme.warning : Theme.error)
                note(timing.wasCold == true
                     ? "Cold — the press started the process."
                     : "Warm — the app was already running.",
                     tint: Theme.textTertiary)
            }

            // **The number the rest of this screen has always rounded down.**
            // `DialTiming` stops when ICE settles, and the microphone then sits at zero
            // gain for the width of the connect cue so server VAD cannot hear it — so
            // every figure above is optimistic by that much. Shown against the same
            // thresholds, because this is the one the user actually sat through.
            if let hearable = timing.hearableMs {
                row("…until you could be heard",
                    "\(DialTiming.format(hearable))ms",
                    tint: hearable <= 2_500 ? Theme.success
                        : hearable <= 4_000 ? Theme.warning : Theme.error)
            }

            row("Placed from", timing.entryPoint, tint: Theme.textSecondary)

            if let toDial = timing.toDialMs {
                row("…of which, before the dial", "\(LaunchTiming.format(toDial))ms")
                ForEach(Array(timing.launchLegs.enumerated()), id: \.offset) { _, leg in
                    row("   \(leg.label)", "\(LaunchTiming.format(leg.ms))ms",
                        tint: Theme.textSecondary)
                }
            }

            if let dialTotal = timing.dialTotalMs {
                row("…of which, the dial", "\(DialTiming.format(dialTotal))ms")
                ForEach(Array(timing.dialLegs.enumerated()), id: \.offset) { _, leg in
                    row("   \(leg.label)", "\(DialTiming.format(leg.ms))ms",
                        tint: Theme.textSecondary)
                }
            }

            // Not a leg, because it happens inside `prepare()`, which runs concurrently
            // with the mint. It is the earliest instant the phone itself could hear the
            // user — long before the session can — which is what makes it the number to
            // beat for anything that lets someone start talking during the dial.
            if let micLive = timing.micLiveMs {
                row("Microphone live at", "\(DialTiming.format(micLive))ms",
                    tint: Theme.textSecondary)
            }

            // Deliberately outside the total: the user can already speak by then. It
            // is when the assistant could answer *about mail or GitHub*, which is what
            // the post-onboarding greeting waits for.
            if let tools = timing.toolsMs {
                row("Tools reachable", "\(DialTiming.format(tools))ms")
            }

            // **One dial proves nothing here and this row is why.** The SDP leg has
            // measured 476 / 1,061 / 1,362 ms across three runs with no code touching it,
            // so the readout above can show a win or a regression that is entirely
            // OpenAI's variance. The median across everything this install has recorded
            // is the only figure a change should be judged on — and it survives the
            // relaunch that reading a cold dial requires.
            if let median = timing.medianMs, timing.recordedDials > 1 {
                row("Median of last \(timing.recordedDials)",
                    "\(DialTiming.format(median))ms",
                    tint: Theme.textSecondary)
            }
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = Theme.textPrimary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)
        }
        .listRowBackground(Theme.surface)
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .listRowBackground(Theme.surface)
    }
}

/// One reading of both timing instruments, taken together.
///
/// `LaunchTiming` and `DialTiming` are lock-guarded statics rather than published
/// properties, because they are written from libwebrtc's threads and from paths that
/// must not suspend. Nothing can observe them, so this copies both at once — which is
/// also what stops the launch half and the dial half being read a frame apart and
/// describing two different dials.
struct DialTimingSnapshot {
    var launchLegs: [LaunchTiming.Leg] = []
    var dialLegs: [DialTiming.Leg] = []
    var toDialMs: Double?
    var toTalkMs: Double?
    var dialTotalMs: Double?
    var toolsMs: Double?
    var wasCold: Bool?
    /// Tap → the microphone was live. The earliest the phone could hear anything, and
    /// the number any "talk before it connects" change is judged on.
    var micLiveMs: Double?
    /// Tap → **OpenAI** could hear you, which is `dialTotalMs` plus the connect cue's
    /// deaf window. The honest figure; see `DialTiming.lastHearableMs`.
    var hearableMs: Double?
    var entryPoint: String = "orb"
    /// The median of every dial this install has recorded, which is the only summary
    /// worth reading on a path whose SDP leg swings 476–1,362 ms untouched.
    var medianMs: Double?
    var recordedDials: Int = 0

    static func current() -> DialTimingSnapshot {
        DialTimingSnapshot(
            launchLegs: LaunchTiming.lastLaunch,
            dialLegs: DialTiming.lastDial,
            toDialMs: LaunchTiming.lastToDialMs,
            toTalkMs: LaunchTiming.lastToTalkMs,
            dialTotalMs: DialTiming.lastTotalMs,
            toolsMs: DialTiming.lastToolsMs,
            wasCold: LaunchTiming.lastWasCold,
            micLiveMs: DialTiming.lastMicLiveMs,
            hearableMs: DialTiming.lastHearableMs,
            entryPoint: DialTiming.lastEntryPoint,
            medianMs: DialTiming.medianTotalMs(),
            recordedDials: DialTiming.recent.count)
    }
}
#endif
