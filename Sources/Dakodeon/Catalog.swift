import Foundation

/// A single file to fetch from Hugging Face (weights or a draft/MTP model).
struct ModelAsset: Hashable {
  /// Hugging Face repository, e.g. `org/name-GGUF`.
  let repo: String
  /// Path of the file inside the repository, e.g. `model-Q8_0.gguf` or `MTP/draft-Q8_0.gguf`.
  let file: String
  /// Expected download size in bytes. Used for progress and the size shown in Settings.
  let bytes: Int64
}

/// A ready-to-run model profile. Profiles are curated here by the maintainer;
/// the app exposes no per-model configuration to the user.
struct ModelProfile: Identifiable, Hashable {
  let id: String
  /// Display name shown in the menu and Settings.
  let name: String
  /// Short one-line descriptor, e.g. "12B · Q8_0 · MTP draft".
  let detail: String
  /// Main weights.
  let weights: ModelAsset
  /// Optional speculative-decoding draft / MTP model.
  let draft: ModelAsset?
  /// Extra `llama-server` flags appended verbatim (after the resolved model paths).
  let extraArguments: [String]

  /// Every asset this profile needs on disk.
  var assets: [ModelAsset] { draft.map { [weights, $0] } ?? [weights] }

  /// Total bytes across all assets.
  var bytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }
}

/// The curated set of model profiles. Edit this list to add or update models.
enum Catalog {
  static let profiles: [ModelProfile] = [
    ModelProfile(
      id: "gemma4-12b-coder",
      name: "Gemma4 12B Coder",
      detail: "12B · Q8_0 · MTP draft",
      weights: ModelAsset(
        repo: "yuxinlu1/gemma-4-12B-coder-fable5-composer2.5-v1-GGUF",
        file: "gemma4-coding-Q8_0.gguf",
        bytes: 12_669_645_344
      ),
      draft: ModelAsset(
        repo: "yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF",
        file: "MTP/gemma-4-12B-it-MTP-Q8_0.gguf",
        bytes: 465_109_248
      ),
      extraArguments: [
        "--spec-type", "draft-mtp",
        "--spec-draft-n-max", "4",
        "--n-gpu-layers-draft", "all",
      ]
    )
  ]

  static func profile(id: String) -> ModelProfile? {
    profiles.first { $0.id == id }
  }
}

enum ByteFormat {
  private static let formatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useGB, .useMB]
    return f
  }()

  static func string(_ bytes: Int64) -> String {
    formatter.string(fromByteCount: bytes)
  }
}
