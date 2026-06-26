import Foundation

/// A single file to fetch from Hugging Face (weights or a draft/MTP model).
struct ModelAsset: Hashable, Sendable {
  /// Hugging Face repository, e.g. `org/name-GGUF`.
  let repo: String
  /// Path of the file inside the repository, e.g. `model-Q8_0.gguf` or `MTP/draft-Q8_0.gguf`.
  let file: String
}

/// A ready-to-run model profile. Profiles are curated here by the maintainer;
/// the app exposes no per-model configuration to the user.
struct ModelProfile: Identifiable, Hashable, Sendable {
  let id: String
  /// Main weights.
  let weights: ModelAsset
  /// Optional speculative-decoding draft / MTP model.
  let draft: ModelAsset?
  /// Optional multimodal vision projector, passed to `llama-server` via `--mmproj`.
  let mmproj: ModelAsset?
  /// Optional chat template written to a profile-specific file and passed via `chat-template-file`.
  let chatTemplate: String?
  /// Extra `llama-server` flags appended verbatim (after the resolved model paths).
  let extraArguments: [String]

  /// Every asset this profile needs on disk.
  var assets: [ModelAsset] { [weights] + [draft, mmproj].compactMap { $0 } }

  /// Display name shown in the menu and Settings — the full Hugging Face repository
  /// (e.g. `deepreinforce-ai/Ornith-1.0-35B-GGUF`).
  var name: String { weights.repo }

  /// Whether this profile ships a speculative-decoding draft / MTP model.
  var hasDraft: Bool { draft != nil }

  /// Whether this profile ships a multimodal vision projector.
  var hasVision: Bool { mmproj != nil }
}

/// The curated set of model profiles. Edit this list to add or update models.
enum Catalog {
  static let profiles: [ModelProfile] = [
    ModelProfile(
      id: "gemma4-26b-a4b-it-qat",
      weights: ModelAsset(
        repo: "unsloth/gemma-4-26B-A4B-it-qat-GGUF",
        file: "gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
      ),
      draft: ModelAsset(
        repo: "unsloth/gemma-4-26B-A4B-it-qat-GGUF",
        file: "mtp-gemma-4-26B-A4B-it.gguf"
      ),
      mmproj: ModelAsset(
        repo: "unsloth/gemma-4-26B-A4B-it-qat-GGUF",
        file: "mmproj-F16.gguf"
      ),
      chatTemplate: nil,
      extraArguments: [
        "-ngl", "999",
        "--spec-type", "draft-mtp",
      ]
    ),
    ModelProfile(
      id: "ornith-1.0-35b",
      weights: ModelAsset(
        repo: "deepreinforce-ai/Ornith-1.0-35B-GGUF",
        file: "ornith-1.0-35b-Q4_K_M.gguf"
      ),
      draft: nil,
      mmproj: nil,
      chatTemplate: ModelTemplates.ornith,
      extraArguments: [
        "-ngl", "999",
        "--reasoning-format", "deepseek",
      ]
    )
  ]

  static func profile(id: String) -> ModelProfile? {
    profiles.first { $0.id == id }
  }
}

enum ByteFormat {
  static func string(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useGB, .useMB]
    return f.string(fromByteCount: bytes)
  }
}
