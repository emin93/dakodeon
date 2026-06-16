import Foundation

/// A single file to fetch from Hugging Face (weights or a draft/MTP model).
struct ModelAsset: Hashable {
  /// Hugging Face repository, e.g. `org/name-GGUF`.
  let repo: String
  /// Path of the file inside the repository, e.g. `model-Q8_0.gguf` or `MTP/draft-Q8_0.gguf`.
  let file: String
  /// Expected download size in bytes. Used for progress and the size shown in Settings.
  let bytes: Int64
  /// LFS SHA-256 used by Hugging Face for the backing blob and partial downloads.
  let blobSHA256: String?

  init(repo: String, file: String, bytes: Int64, blobSHA256: String? = nil) {
    self.repo = repo
    self.file = file
    self.bytes = bytes
    self.blobSHA256 = blobSHA256
  }
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
      id: "gemma4-12b-it-qat",
      name: "Gemma 4 12B IT QAT",
      detail: "12B · UD-Q4_K_XL · MTP draft",
      weights: ModelAsset(
        repo: "unsloth/gemma-4-12B-it-qat-GGUF",
        file: "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf",
        bytes: 6_716_355_328,
        blobSHA256: "cc9ff072e0a8203429ed854e6662c17a6c2bc1e5dca5b475dd4736caaacbc165"
      ),
      draft: ModelAsset(
        repo: "unsloth/gemma-4-12B-it-qat-GGUF",
        file: "mtp-gemma-4-12B-it.gguf",
        bytes: 253_707_328,
        blobSHA256: "c50c91c35f04903815b2e8930cbb8c8c5bee0e1aa00748c30a7b8ff05d2310b4"
      ),
      extraArguments: [
        "-ngl", "999",
        "-fa", "on",
        "--spec-type", "draft-mtp",
        "--spec-draft-n-max", "4",
        "--n-gpu-layers-draft", "all",
      ]
    ),
    ModelProfile(
      id: "gemma4-31b-it-qat",
      name: "Gemma 4 31B IT QAT",
      detail: "31B · UD-Q4_K_XL · MTP draft",
      weights: ModelAsset(
        repo: "unsloth/gemma-4-31B-it-qat-GGUF",
        file: "gemma-4-31B-it-qat-UD-Q4_K_XL.gguf",
        bytes: 17_287_668_064,
        blobSHA256: "9188a71055550f1e60b875d02b7abb63625ac11b4a6f148d6b22b3b28ba3d335"
      ),
      draft: ModelAsset(
        repo: "unsloth/gemma-4-31B-it-qat-GGUF",
        file: "mtp-gemma-4-31B-it.gguf",
        bytes: 279_954_368,
        blobSHA256: "b5c4e583fc5982439080114bbc1b7edaec361f9d4c9193d6bed606a3de401b62"
      ),
      extraArguments: [
        "-ngl", "999",
        "-fa", "on",
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
