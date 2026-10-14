import Foundation

/// What one response cost, read off the Live backend's usage. Near-zero `cached` on a call's first response
/// and thousands on the second means the first ask paid for uncached prefill; compare medians, not one dial.
struct ResponseUsage: Equatable {
    /// Everything the model read to produce this response: the prefix plus the conversation so far.
    var inputTokens: Int?
    /// How much of `inputTokens` came from cache rather than being recomputed.
    var cachedTokens: Int?
    /// The audio half of `cachedTokens`, where OpenAI breaks it out. Audio is the expensive input, so a cache
    /// that misses it saves almost nothing.
    var cachedAudioTokens: Int?
    var cachedTextTokens: Int?

    /// Nothing was reported. Not a zero-token response, which would fake a 0% cache rate.
    var isEmpty: Bool { inputTokens == nil && cachedTokens == nil }

    /// The share of the input that was cached. Nil when there is no input.
    var cachedPercent: Int? {
        guard let inputTokens, inputTokens > 0, let cachedTokens else { return nil }
        return Int((Double(cachedTokens) / Double(inputTokens) * 100).rounded())
    }
}

/// The session events the voice client handles, emitted by `LiveSessionAdapter`.
enum RealtimeEvent: Equatable {
    case sessionCreated(model: String?)

    /// Output-audio playback lifecycle: the only honest signal that the speaker is making noise.
    case outputAudioStarted
    case outputAudioStopped

    // The assistant's own words.
    /// - Parameter spoken: `true` for the transcript of audio the model generated, `false` when it returned
    ///   text instead, which never reaches the speaker.
    case assistantTranscriptDelta(itemId: String, delta: String, spoken: Bool)
    case assistantTranscriptDone(itemId: String, transcript: String)

    // Backend-executed tools.
    case mcpToolsListed
    /// A backend tool call beginning. The item id tells a repeat report of one call from a second call to the same tool.
    case mcpCallStarted(name: String?, itemId: String?)
    case mcpCallCompleted
    case mcpCallFailed(message: String?)

    /// A finished backend tool call. `itemJSON` is the item verbatim, never parsed; `name` and `arguments`
    /// are lifted out as the store's key.
    case mcpCallResult(
        name: String, serverLabel: String?, argumentsJSON: String, itemJSON: String)

    case error(message: String, code: String?)
}
