import Foundation

extension FullDuplexVoiceClient {

    // MARK: - Announcing the call

    /// Play the connect cue with the microphone held shut for its length.
    ///
    /// **The duck is the load-bearing half.** The cue is rendered by our own
    /// `AVAudioEngine`, so it is not in libwebrtc's reference signal and its echo
    /// canceller cannot remove it. Left audible to the network, server VAD would hear
    /// a tone the instant the call opened and answer it — the assistant's first act
    /// on every dial would be replying to its own chime. Gain 0 rather than
    /// `setMuted`, because mute is the user's lever and this must not appear to move
    /// it.
    ///
    /// Sound the "go ahead" the moment the *phone* can hear the user, rather than when
    /// OpenAI can.
    ///
    /// **The cue lived at `.connected` because before that there was nothing to say.**
    /// Nothing captured the dial, so a chime inviting speech would have been a lie — the
    /// words went nowhere. Talking early makes it true: from `micLive` the capture tap is
    /// running, `LocalTranscriber` is transcribing, and what is said is delivered when the
    /// session opens. So the honest moment to invite speech moved from ~2,000 ms to ~10.
    ///
    /// **And the rule it looks like it breaks, it does not.** `ConnectCue`'s header is
    /// emphatic that from mic-track-add the room must be quiet, because our cue is rendered
    /// by a separate `AVAudioEngine`, is absent from libwebrtc's reference signal, and
    /// server VAD reads it as speech. That reasoning is about a *session*: here there is no
    /// peer connection, no uplink and no VAD — the SDP handshake has not happened. Nothing
    /// can hear this but the user and our own capture tap.
    ///
    /// The capture tap is the one real hazard, and it is why the transcriber is
    /// suppressed across the cue: `LocalTranscriber` would otherwise transcribe the chime
    /// into the words handed off at connect. `setSuppressed` stops it *publishing* while
    /// still absorbing, and flushes on release, so speech that starts during the cue is
    /// not lost — `setMuted` was doing this job and discarded those words instead.
    ///
    /// **The pre-roll is why this waits rather than firing on the signal.** VPIO wants
    /// ~400 ms of quiet room to converge its echo canceller, and playing into that window
    /// is the one thing that would genuinely cost something. Today the mint hides that
    /// wait (`pre-roll remainder` reads 0), so by the time this fires the canceller has
    /// already had its quiet room.
    ///
    /// The honest cost: this cue used to mean "the call is up", and now it means "start
    /// talking, I am recording". A dial that fails after it has told the user to speak,
    /// which the connect-time cue could never do. That is the trade talking early makes
    /// everywhere else.
    func announceReady() {
        // A speak-first opening is deliberately not an invitation to talk. Claim the cue so
        // `announceConnect()` cannot play it a second later.
        guard !openingHold, !flowHold else {
            if announcesConnect {
                hasAnnouncedConnect = true
                DialTiming.noDeafWindow()
                RealtimeLog.log("ready cue: suppressed while Jo owns the opening")
            }
            return
        }
        guard announcesConnect, !hasAnnouncedConnect else { return }
        hasAnnouncedConnect = true
        // No cue at connect means no zero-gain window after it, so `first listen` really
        // is when the user can be heard. Without this the summary keeps adding 750 ms for
        // a wait that no longer happens.
        DialTiming.noDeafWindow()
        cueTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: FullDuplexAudioSession.vpioPreRoll)
            guard self.isActive else { return }
            // Suppression holds recognized words until the cue ends; mute would discard them.
            self.transport?.localTranscriber.setSuppressed(true)
            // And the meter with it, for the same reason: the cue is rendered by our own
            // `AVAudioEngine`, so it is absent from libwebrtc's reference signal and
            // reaches the capture tap. Left reporting, the mercury thread would swell on
            // the app's own chime in the first second of the call — "it thinks I'm
            // speaking", told at the one moment the user is watching for exactly that.
            self.transport?.micMeter.setMuted(true)
            RealtimeLog.log("ready cue: inviting speech before the session is up")
            // **The buzz and the bloop are one signal, so they are fired from one line.**
            // `Haptics.callReady()` used to hang off the `.connecting → .listening`
            // transition in `CommandView`, which was right when the cue also lived at
            // connect. With the cue at mic-live those are a second apart and the haptic
            // arrives after the sound, which reads as two separate events rather than one
            // "go ahead". Routing it through a published flag and a view would put a
            // main-actor hop between them for no benefit — both are `@MainActor` already,
            // so this is the tightest sync available.
            //
            // `stopWaiting` first: the 400 ms ticks mean "still working" and must not keep
            // running underneath a cue that says the opposite.
            Haptics.stopWaiting()
            Haptics.callReady()
            await self.connectCue.play()
            self.transport?.localTranscriber.setSuppressed(false)
            // Unconditionally, unlike the transcriber above: the thread is drawn only
            // while the mic has the floor, and `CommandView.micHasTheFloor` already
            // refuses a muted one. A meter that stayed shut after an unmute would be the
            // second lie this pair exists to prevent.
            self.transport?.micMeter.setMuted(false)
            RealtimeLog.log("ready cue: done — the phone is listening")
        }
    }

    func announceConnect() {
        guard announcesConnect, !hasAnnouncedConnect else { return }
        hasAnnouncedConnect = true
        cueTask = Task { [weak self] in
            guard let self else { return }
            self.setMicGain(0)
            // Logged here rather than in `setMicGain`, which runs on every reply and
            // would drown the console. This is the window the
            // `.speechStarted` warning below is measured against.
            RealtimeLog.log("connect cue: mic at gain 0 for \(ConnectCue.micDeafWindow)")
            await self.connectCue.play()
            // The level at gain 0, logged for the same reason as the warning below:
            // this window is the only place in a normal call where the gain is
            // pinned to a known value while audio is definitely playing, so it is
            // the cheapest read there is on whether the gain reaches the uplink at
            // all. A `mic` that hasn't collapsed here says it doesn't.
            RealtimeLog.log(String(format: "connect cue: mic %.3f at gain 0", self.levels.mic))
            // Deliberately not guarded on cancellation. On End the transport is
            // already nil; on a redial it is a fresh object whose gain is 1.0
            // regardless. A late restore is a no-op in both cases rather than
            // something to defend against.
            self.setMicGain(1)
            RealtimeLog.log("connect cue: mic gain restored")
        }
    }

    /// Take back a refusal the model made because its tools had not loaded yet.
    ///
    /// **A conversation item, because the thing that is wrong is in the conversation.** A
    /// model that has said its mail tools are unavailable has put that in its own context,
    /// and every later turn reasons from it. That is what turned a 3.4-second gap into a
    /// call the user had to abandon: the tool list landed 34 seconds before the last ask and
    /// the refusal came anyway, twice, from a model quoting itself. Nothing re-derives a
    /// claim it has already made, so the only fix is to put the correction where the claim
    /// is.
    ///
    /// **No `response.create`, deliberately.** This must not make the assistant say
    /// anything: it lands silently and takes effect on the turn the user asks for next.
    /// Speaking here would talk over whichever turn is still in flight — on the measured
    /// case the tools arrived *mid-refusal* — and announce plumbing the user never asked
    /// about. `conversation.item.create` on its own does not schedule a response, which is
    /// exactly the property being relied on.
    ///
    /// Fires at most once per dial, on the `answeredWithoutTools` latch: a second copy
    /// would be a second permanent instruction, and the flag it reads is what keeps a
    /// healthy dial — where nothing was refused — from paying for this at all.
    func announceToolsArrived() {
        guard answeredWithoutTools else { return }
        answeredWithoutTools = false
        RealtimeLog.log("tools: correcting the session — the model refused before the list "
            + "landed, and the refusal is still in its context")
        // Phrased to retire the claim *and* to finish the errand, because taking back the
        // refusal alone is not enough: in the reported case the request had already been
        // made twice. A note that only says "you have tools now" leaves the model waiting to
        // be asked a third time.
        transport?.sendContextItem(
            "Your tools have finished loading and are all available now. If you just told "
                + "the user you could not reach their mail, calendar or anything else "
                + "because tools were missing or not connected, that is no longer true — do "
                + "not say it again, and do not send them to Settings. Carry out what they "
                + "already asked for, without making them repeat it.",
            role: "system",
        )
    }
}
