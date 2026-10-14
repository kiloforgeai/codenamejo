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
        // `announceConnect()` cannot play it a second later; that method still closes the
        // empty pre-connect handoff when the session connects.
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
            // Suppressed across the cue and released after, so the chime never becomes
            // words in `preConnectText`. `setSuppressed` rather than `setMuted`: the
            // words are kept and flushed on release, because this window *is* the
            // invitation to talk and mute discards what it hears.
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
        // **A dial with no cue still has to hand off.** `reconnect()` passes
        // `playingCue: false`, and the hand-off lives at the end of the cue task below —
        // so without this a redial would leave the gate open forever, quietly collecting
        // every later sentence as "pre-connect" speech and injecting none of it. There is
        // no deaf window on that path, so the uplink is already open and now is the edge.
        // **A dial that plays no cue here still has to hand off**, and there are now two
        // ways to reach that. `reconnect()` passes `playingCue: false`; and
        // `announceReady` has already sounded the cue at mic-live and
        // claimed `hasAnnouncedConnect`, so this would return with the words still held.
        // Either way the uplink is open from here, so this is the edge to hand off on.
        //
        // **The deaf window is skipped on that path, and that is the point.** It exists so
        // server VAD cannot hear the chime — and the chime already played, seconds ago,
        // into a session that did not exist. Nothing is left to hide from VAD, so the 750 ms
        // of zero gain (which measurement shows leaks anyway, `mic 0.400 at gain 0`) buys
        // nothing and costs the user the start of their sentence.
        //
        // **And it is the path that answered without tools in the reported case.** No deaf
        // window means the uplink is open and server VAD is live from this instant — so the
        // sentence was committed and answered at T+2.5 s, 3.4 s before `tools/list` landed,
        // and the model reported the mailbox unreachable. Holding the *injection* alone
        // would have changed nothing, because the injection was not what answered: the turn
        // has no `latency` row, which is the signature of the `sendContextItem` branch where
        // VAD owns the reply. The uplink itself is what has to wait.
        //
        // Waiting here is free of the cost the paragraph above objects to. Zero gain stops
        // the *uplink*, and `LocalTranscriber` sits on the capture tap upstream of it — the
        // words keep accumulating in `preConnectText` and go up in the hand-off, which is
        // the same property `handOffWhenUtteranceEnds` has always relied on. So the start of
        // the sentence is not lost; it arrives as text instead of audio.
        guard announcesConnect, !hasAnnouncedConnect else {
            // The common case, and it stays byte-identical: `tools/list` normally completes
            // before the dial does, so there is nothing to wait for and no gain to touch.
            // `preConnectText.isEmpty` takes the same exit for a different reason — with
            // nothing captured there is no text to protect, and ducking a microphone the
            // user has not spoken into would swallow words that no transcriber is holding.
            guard !toolsReachable, !preConnectText.isEmpty else {
                handOffPreConnectSpeech()
                return
            }
            RealtimeLog.log("talk-early: the call is up but its tools are not — holding the "
                + "uplink rather than answering without them")
            cueTask = Task { [weak self] in
                guard let self else { return }
                self.setMicGain(0)
                await self.handOffWhenUtteranceEnds()
                // Same reasoning as the cue path below: a late restore is a no-op on End
                // and on a redial, so this is deliberately not guarded on cancellation.
                self.setMicGain(1)
                RealtimeLog.log("talk-early: mic gain restored")
            }
            return
        }
        hasAnnouncedConnect = true
        cueTask = Task { [weak self] in
            guard let self else { return }
            self.isAnnouncingConnect = true
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
            self.isAnnouncingConnect = false
            // **The hand-off comes before the gain is restored, and it waits for the
            // sentence to finish. Both of those were learned on device.**
            //
            // The cue window is a clean cut in *time* and the first version treated that
            // as good enough — inject whatever had been said, restore the gain, let audio
            // take over. It is not good enough, because a person does not stop talking
            // when the network becomes ready. Measured on an iPhone 17 Pro against a
            // preview broker: `handing off "Can you check my"` and `handing off "Let's
            // start my"`, two sentences cut where the 750 ms happened to land. The model
            // got a fragment as text and the rest of the sentence arrived seconds later
            // as a separate audio turn.
            //
            // So the microphone stays shut until the *speaker* stops, not until the
            // network is ready. `handOffWhenUtteranceEnds` waits for a gap in the local
            // transcript, injects the whole utterance, and only then does the gain come
            // back — which is why the restore moved below this line rather than above
            // it. Whatever is said after that gap is a new turn and goes as audio, which
            // is exactly what it should be.
            await self.handOffWhenUtteranceEnds()
            // Deliberately not guarded on cancellation. On End the transport is
            // already nil; on a redial it is a fresh object whose gain is 1.0
            // regardless. A late restore is a no-op in both cases rather than
            // something to defend against.
            self.setMicGain(1)
            RealtimeLog.log("connect cue: mic gain restored")
        }
    }

    /// Hold the uplink closed until the user finishes the sentence they started during
    /// the dial, then hand the whole of it over.
    ///
    /// **The end-of-utterance signal has to be local, because there is no other one.**
    /// Server VAD draws turn boundaries everywhere else in this class, and by definition
    /// it has not heard a word of this — the audio never reached it. `LocalTranscriber`
    /// publishes continuously while someone is talking and stops when they stop, so a gap
    /// in its output is the only evidence available that a sentence ended.
    ///
    /// Nothing captured means nothing to wait for: that path closes the gate immediately
    /// and the call behaves exactly as it did before this feature existed.
    ///
    /// The poll is 50 ms against a 400 ms window, on the main actor, doing a comparison —
    /// a `CheckedContinuation` woken from the transcript callback would be tidier and is
    /// not worth the extra state on a path that runs once per call and is bounded by
    /// `preConnectMaxHold`.
    private func handOffWhenUtteranceEnds() async {
        guard !hasHandedOffPreConnect, !preConnectText.isEmpty else {
            handOffPreConnectSpeech()
            return
        }
        let started = ContinuousClock.now
        while ContinuousClock.now - started < Self.preConnectMaxHold {
            if let last = preConnectLastChangeAt,
               ContinuousClock.now - last >= Self.preConnectSettle {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
            // End, a redial or a transport failure while we were waiting. The call this
            // was holding the microphone for no longer exists.
            guard isActive else { return }
        }
        let held = ContinuousClock.now - started
        RealtimeLog.log("talk-early: held the uplink \(held) waiting for the sentence to end")
        // **The sentence first, then the tools, and that order is not arbitrary.** Waiting
        // for the tools while the user is still mid-sentence would spend the same wall
        // clock twice — the transcript is still moving, so the settle loop above has not
        // finished deciding what to hand over. By here the utterance is whole and the only
        // thing left to wait on is the server.
        await awaitToolsReachable()
        handOffPreConnectSpeech()
    }

    /// Give the model what the user said while the call was still coming up.
    ///
    /// **This is the answer to a wait that is mostly not ours to shorten.** A cold dial
    /// is ~2.6 s before OpenAI can hear anything, and measurement put 62% of it
    /// inside two OpenAI round trips, against ~500 ms that this
    /// codebase executes across the entire dial. Shaving our half harder has a floor;
    /// removing the *experience* of the wait does not.
    ///
    /// Route A of that document's §3: the words go up as `input_text`, because they
    /// already exist for free — `LocalTranscriber` has been running on-device for the
    /// whole dial and nothing consumed it. Route B (buffering the PCM and replaying it
    /// as `input_audio_buffer.append`) keeps prosody and OpenAI's own transcription, and
    /// is deliberately not attempted here: it is unverified over the WebRTC data channel,
    /// its interaction with server VAD is unknown, and that channel is where a stray
    /// frame can wipe the session's MCP tools.
    ///
    /// **Whether to ask for a response is decided per dial, and getting it wrong is
    /// audible in both directions.** The words injected here never passed through server
    /// VAD, so if nothing else is coming, nothing will ever decide the turn is over and
    /// the call opens in silence after the user has already spoken — that is the case
    /// `response.create` exists for. But measured on device, the cue's zero-gain window
    /// does not reliably silence the uplink, so OpenAI often *has* heard the tail of the
    /// sentence, committed it and started answering. Asking again there is a straight
    /// `conversation_already_has_active_response`, and the injected item is wasted.
    ///
    /// So the item always goes — it is the part of the sentence the session genuinely
    /// missed, and it lands in the conversation where the model can use it — and the
    /// response is requested only when no server turn is in flight. When one is, its
    /// answer covers both halves, which is the outcome we wanted anyway.
    ///
    /// Idempotent by the flag rather than by emptiness: a dial where the user said
    /// nothing must still close the gate, or the first thing they say *after* connecting
    /// would be collected as pre-connect speech and injected on top of the audio the
    /// session is already hearing.
    private func handOffPreConnectSpeech() {
        guard !hasHandedOffPreConnect else { return }
        hasHandedOffPreConnect = true
        let spoken = preConnectText.trimmingCharacters(in: .whitespacesAndNewlines)
        preConnectText = ""
        guard !spoken.isEmpty else { return }
        // **Whether to ask for a reply depends on whether the sentence is finished**, and
        // with the cue moved to mic-live there is a clean way to tell. The deaf window is
        // gone from this path, so audio flows normally from the moment the call is up:
        // anything said from here reaches OpenAI on its own and server VAD will close the
        // turn and answer it. What it never heard is the *head* of the sentence, spoken
        // while the session was still being built — that is what goes up here.
        //
        // So: if the user is still mid-sentence, this is context and VAD owns the reply,
        // which is how the two halves end up in one answer instead of two. If they have
        // stopped, no VAD turn is coming and nothing else will ever decide the turn is
        // over — so this has to ask, or the call opens in silence after they have spoken.
        //
        // Freshness of the local transcript is the test, and it is the same signal
        // `handOffWhenUtteranceEnds` waits on. Note this replaced a cancel-and-replace
        // against the server's turn, which existed only because the old deaf window leaked
        // audio to VAD and produced a garbage turn to take back. No deaf window, no leak,
        // nothing to cancel.
        let stillSpeaking = preConnectLastChangeAt.map {
            ContinuousClock.now - $0 < Self.preConnectSettle
        } ?? false
        RealtimeLog.log("talk-early: handing off \"\(spoken)\""
            + (stillSpeaking ? " — still talking, context only" : " — asking for a reply"))
        if stillSpeaking {
            transport?.sendContextItem(spoken, role: "user")
        } else {
            // **Timed from here, and it never used to be.** `beginLatencyTurn` has one
            // other caller, on `speech_stopped` — an event an injected turn by
            // definition never produces. So the talk-early first turn, on the most
            // common dial in the app, was the one turn with no instrumentation at all:
            // it emitted no row, so every turn-1 figure measured before this silently
            // described ordinary VAD turns only. `preConnectLastChangeAt` is the honest
            // mark — the hand-off
            // waited out `preConnectSettle` before deciding, and counting that wait
            // against the model would flatter it.
            latencyUtterance = spoken
            beginLatencyTurn(localEndOfUtterance: preConnectLastChangeAt)
            transport?.sendUserText(spoken)
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

    /// Hold until the session's tools can actually be called, or until waiting stops being
    /// worth it.
    ///
    /// **The measurement is what makes this cheap.** `tools/list` completes at ~1,833 ms
    /// against a dial that finishes at 1,546 ms warm and 2,751 ms cold, so on
    /// a healthy dial the tools are already there when this is reached and it returns
    /// without sleeping. It only ever costs anything on the dial that would otherwise
    /// produce a wrong answer — 3.4 s in the one measured failure, where the alternative
    /// was a refusal and a redial.
    ///
    /// Bounded because a wait with no ceiling is a call that never opens its microphone,
    /// which is the same reason `preConnectMaxHold` has one. Past the bound the words go up
    /// regardless: a late answer is recoverable and a swallowed sentence is not.
    private func awaitToolsReachable() async {
        guard !toolsReachable else { return }
        let started = ContinuousClock.now
        while ContinuousClock.now - started < Self.toolsMaxHold {
            try? await Task.sleep(for: .milliseconds(50))
            // End, a redial or a transport failure while we were waiting. Same guard
            // `handOffWhenUtteranceEnds` makes, for the same reason: the call this was
            // holding the microphone for no longer exists.
            guard isActive else { return }
            if toolsReachable { break }
        }
        let held = ContinuousClock.now - started
        RealtimeLog.log("talk-early: held the uplink \(held) waiting for the tool list"
            + (toolsReachable ? "" : " — gave up, handing off without it"))
    }
}
