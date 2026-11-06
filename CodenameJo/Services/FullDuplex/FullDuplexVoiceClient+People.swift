import FactoryKit
import Foundation

extension FullDuplexVoiceClient {
    // MARK: - People

    /// `find_person`, answered out of the phone's correspondent directory.
    ///
    /// **The server's version searches; this one looks up.** `gmail_find_person` runs a
    /// Gmail query plus twelve parallel metadata fetches per inbox — p50 458 ms, and 704 ms
    /// measured for a name asked five times in nine days. `ContactScan` has already done
    /// that walk in the background, over far more mail, so this is an indexed read.
    ///
    /// **An empty answer means the walk has not run yet as often as it means the person is
    /// unknown**, and the two are not distinguishable here. Saying so is what stops the
    /// model reporting "you have never emailed them" about a directory that is simply
    /// still empty — the one wrong answer this tool can give that sounds authoritative.
    func answerFindPerson(callId: String, argumentsJSON: String) {
        let name = (Self.stringArgument("name", in: argumentsJSON) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        FullDuplexTrace.note("!! find_person \"\(name)\"")

        // Outside the `Task` — see `answerContextSearch`. `@MainActor` queueing is not free.
        let started = Date()
        Task { [weak self, localContext] in
            let store = ContactStore(database: localContext.dbPool)
            let (output, outcome, detail) = await Self.resolvePerson(name, store: store)
            guard let self, self.isActive else { return }
            self.finishContextTool(
                callId: callId,
                tool: "find_person",
                output: output,
                ms: Date().timeIntervalSince(started) * 1000,
                outcome: outcome,
                query: name,
                detail: detail,
                subsystem: "findPerson"
            )
        }
    }

    /// The answer, its dashboard outcome, and the log line. Split out so the shape is
    /// readable without the plumbing around it, and so a dispatched job answers from the same directory.
    nonisolated static func resolvePerson(
        _ name: String, store: ContactStore
    ) async -> (output: String, outcome: String, detail: String) {
        guard !name.isEmpty else {
            return ("No name to look up — ask the user who they mean.", "local_empty", "no name")
        }
        // Already an address, so this becomes a correspondence check rather than a name
        // lookup — the model has the recipient either way, so every branch below still
        // says "use it as the recipient" and only the wording of the second half changes.
        // Used to short-circuit here with no check at all, on the reasoning that a lookup
        // was needless cost for something the model was already holding — true of the
        // search this replaced, not of an indexed read, and the gap meant a dictated
        // address could never surface a first-time-recipient signal at all: skills/email.md
        // asks the model to say when find_person comes back with no match, and for a
        // spelled-out address it structurally never could.
        if name.contains("@") {
            let bare = name.lowercased()
            if await store.hasCorresponded(email: bare) {
                return (
                    "\(name) is already an address — use it as the recipient.",
                    "local_hit", "already an address, known"
                )
            }
            let held = await store.count()
            let output = held == 0
                ? "\(name) is already an address, but no address book on this device yet "
                    + "— can't confirm whether you've mailed it before. Use it as the "
                    + "recipient."
                : "\(name) is already an address, but there's no history with it in "
                    + "\(held) known correspondent(s) — ask the user \"is that the right "
                    + "person?\" before sending. send_email and forward_email will refuse "
                    + "it until you do."
            return (
                output, "local_empty",
                held == 0 ? "already an address, directory empty" : "already an address, no match"
            )
        }

        // Scoped to the mailboxes still connected, so a row that outlived its
        // account cannot answer — see `ContactStore.purgeAll`.
        let connected = GoogleAccountStore.emails()
        let found = await store.matches(name: name, accounts: connected)
        let matches = found.matches
        guard !matches.isEmpty else {
            let held = await store.count()
            // The distinction that matters: an empty directory has not answered the
            // question, and the model must not report it as though it had.
            let output = held == 0
                ? "No address book on this device yet — ask the user to say the address."
                : "No match for \"\(name)\" in \(held) known correspondent(s). "
                    + "Say you don't have an address for them and ask them to say it."
            return (output, "local_empty", held == 0 ? "directory empty" : "no match of \(held)")
        }

        let json = (try? JSONEncoder().encode(matches))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // **A fuzzy hit has to say so.** Nothing shared a token with the spoken name, so
        // these are nearest-in-meaning guesses; unlabelled, the model reads one candidate
        // as the clear leader and mails a stranger.
        guard found.fuzzy else {
            return (json, "local_hit", "\(matches.count) candidate(s) by name")
        }
        // **Lead with the person, not the miss.** "I couldn't find a clear match"
        // reads as failure before it reads as an answer, and the answer is
        // usually right — it just has to be confirmed rather than acted on.
        let who: String = matches.count == 1 ? "this person" : "one of these"
        let hedged = "Sounds like \(who), spelled differently to what you heard. "
            + "Say the name and address, then ask if that's who they meant — "
            + "do not send until they say yes:\n" + json
        return (hedged, "local_fuzzy", "\(matches.count) candidate(s) by sound")
    }

    // MARK: - Clock

    /// `current_time`, answered off this phone's own clock.
    ///
    /// **The zone is the device's, which is the whole change and the whole cost.** The
    /// broker read it from the user's Google Calendar setting so that the clock agreed with
    /// what "tomorrow morning" means to the calendar tools — correct, and 248 ms of
    /// `GET /calendars/primary` on a path the user is listening to. The phone already knew
    /// `TimeZone.current`, so it was waiting on a server to ask Google something it knew.
    ///
    /// **The `post_at` sentence is carried over verbatim from the broker's version.** It is
    /// the only place anything says a Unix timestamp is computed by adding seconds to this
    /// number rather than guessed, and the failure it prevents is a Slack message scheduled
    /// for the wrong hour, which nobody notices until it sends.
    ///
    /// Synchronous work, still reported through `finishContextTool` — `search_unread`
    /// recorded what skipping that plumbing costs: a tool that demonstrably ran and left no
    /// trace any server could see.
    func answerCurrentTime(callId: String) {
        let started = Date()
        let now = Date()
        let zone = TimeZone.current
        // `en_CA` and full/short to match what the broker's `toLocaleString("en-CA", …)`
        // spoke for its whole life. The model reads this out, so a change of format here is
        // a change to what the user hears.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = zone
        let output = "It is \(formatter.string(from: now)) in \(zone.identifier), and Unix "
            + "time is \(Int(now.timeIntervalSince1970)). Any tool wanting a Unix "
            + "timestamp — post_at — is counted from that number by adding the seconds "
            + "between now and the moment the user named. Never guess one and never say one "
            + "out loud."
        finishContextTool(
            callId: callId,
            tool: "current_time",
            output: output,
            ms: Date().timeIntervalSince(started) * 1000,
            // The vocabulary the other device-answered tools use: nothing was asked of the
            // network, so the dashboard's OUTCOME column should say so.
            outcome: "local_hit",
            // Empty, like the twelve rows the broker wrote before the move — the tool takes
            // no arguments, and a placeholder here would make the before and after
            // incomparable in the one table where the 248 ms is visible.
            query: "",
            detail: zone.identifier,
            subsystem: "clock"
        )
    }
}
