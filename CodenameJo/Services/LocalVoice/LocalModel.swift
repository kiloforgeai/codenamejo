import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Which model answers a local call's on-device turns: Gemma 4 with Jo's tool adapter through
/// MLX when its checkpoint is on the phone, else Apple's; Gemma untuned and Apple's Private Cloud
/// Compute model are selectable for comparison.
enum LocalModel {
    static let key = "localModel"
    static let gemmaName = "gemma"
    static let cloudName = "cloud"
    static let tunedName = "tuned"

    /// The stored choice, or, in a debug build, `LOCAL_MODEL` at launch.
    static var choice: String? {
        #if DEBUG
        if let launch = ProcessInfo.processInfo.environment["LOCAL_MODEL"] { return launch }
        #endif
        return UserDefaults.standard.string(forKey: key)
    }

    /// Apple's server model, when iOS 27 and the choice say so. Needs Apple's managed
    /// com.apple.developer.private-cloud-compute entitlement; without it the framework traps.
    static var usesCloud: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return choice == cloudName
    }

    /// Gemma when the stored choice says so, or, in a debug build, `LOCAL_MODEL=gemma` at launch.
    static var usesGemma: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return choice == gemmaName
    }

    /// Gemma 4 with the Jo adapter fused in: the default whenever the checkpoint has been copied
    /// to the phone, so a launch from the home screen uses it too.
    static var usesTuned: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return (choice == nil || choice == tunedName) && Tuned.isPresent
    }

    /// Whether a model other than Apple's answers the on-device turns.
    static var usesOther: Bool { usesGemma || usesCloud || usesTuned }

    /// Loads the selected MLX model, downloading or reading it the first time.
    static func preload() async throws {
        guard #available(iOS 27.0, *) else { return }
        if usesTuned { try await Tuned.preload() } else if usesGemma { try await Gemma.preload() }
    }

    /// A session on the selected model, with the same tools and instructions either way.
    static func session(tools: [any FoundationModels.Tool], instructions: String) -> LanguageModelSession {
        if usesTuned, #available(iOS 27.0, *) {
            return LanguageModelSession(model: Tuned.model, tools: tools, instructions: Instructions(instructions))
        }
        if usesGemma, #available(iOS 27.0, *) {
            return LanguageModelSession(model: Gemma.model, tools: tools, instructions: Instructions(instructions))
        }
        if usesCloud, #available(iOS 27.0, *) {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools,
                                        instructions: Instructions(instructions))
        }
        return LanguageModelSession(tools: tools, instructions: instructions)
    }

    @available(iOS 27.0, *)
    enum Gemma {
        static let model = #huggingFaceLanguageModel(configuration: LLMRegistry.gemma4_e4b_it_4bit,
                                                     capabilities: [.toolCalling, .guidedGeneration])

        /// Downloads the weights the first time (about 5 GB) and loads them, logging how long it took.
        static func preload() async throws {
            let started = Date()
            RealtimeLog.log("local-model: gemma \(String(describing: await model.availability)), loading")
            try await model.preload()
            RealtimeLog.log("local-model: gemma ready in \(Int(Date().timeIntervalSince(started))) s")
        }
    }

    /// The fused Gemma 4 checkpoint with the Jo tool adapter, copied into Application Support
    /// (2.5 GB for E2B, 4 GB for E4B); see `lora/README.md`.
    @available(iOS 27.0, *)
    enum Tuned {
        /// The smaller checkpoint wins when both have been copied over.
        static let directory: URL = {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let candidates = ["gemma-4-e2b-jo", "gemma-4-e4b-jo"].map { support.appendingPathComponent($0, isDirectory: true) }
            return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
                ?? candidates[0]
        }()

        static var isPresent: Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
        }

        static let model = MLXLanguageModel(
            configuration: ModelConfiguration(directory: directory),
            capabilities: [.toolCalling, .guidedGeneration],
            weightsLocation: { _ in directory },
            load: { configuration, progressHandler in
                try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                                             configuration: configuration, progressHandler: progressHandler)
            })

        static func preload() async throws {
            let started = Date()
            RealtimeLog.log("local-model: tuned gemma \(String(describing: await model.availability)) at \(directory.path), loading")
            try await model.preload()
            RealtimeLog.log("local-model: tuned gemma ready in \(Int(Date().timeIntervalSince(started))) s")
        }
    }
}
