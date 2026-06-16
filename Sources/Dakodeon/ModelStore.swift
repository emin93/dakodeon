import Foundation

enum ModelStatus: Equatable {
  case absent
  case downloading(progress: Double, completed: Int64, total: Int64)
  case ready(bytes: Int64)
  case failed(String)

  var isDownloading: Bool { if case .downloading = self { return true } else { return false } }
  var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// Manages model files in the Hugging Face cache: status, downloads, and deletion.
///
/// Downloads run through the `hf` CLI; progress is derived by polling bytes on disk
/// against the known asset sizes, and deletion removes the backing blobs directly.
@MainActor
final class ModelStore: ObservableObject {
  @Published private(set) var statuses: [String: ModelStatus] = [:]

  private let hubURL: URL
  private let environment: [String: String]
  private var downloads: [String: Download] = [:]
  private var pollTimers: [String: Timer] = [:]

  init() {
    self.hubURL = Self.resolveHubURL()
    self.environment = Self.makeEnvironment()
    refreshAll()
  }

  // MARK: - Status

  func status(for profile: ModelProfile) -> ModelStatus {
    statuses[profile.id] ?? .absent
  }

  func isComplete(_ profile: ModelProfile) -> Bool {
    profile.assets.allSatisfy { localURL(for: $0) != nil }
  }

  /// Resolved on-disk path for an asset, or nil if it is not present.
  func localURL(for asset: ModelAsset) -> URL? {
    let snapshots = repoURL(asset.repo).appendingPathComponent("snapshots")
    guard let revisions = try? FileManager.default.contentsOfDirectory(
      at: snapshots, includingPropertiesForKeys: nil) else { return nil }
    for revision in revisions {
      let candidate = revision.appendingPathComponent(asset.file)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  func refreshAll() {
    for profile in Catalog.profiles { refresh(profile) }
  }

  func refresh(_ profile: ModelProfile) {
    guard downloads[profile.id] == nil else { return }
    statuses[profile.id] = isComplete(profile) ? .ready(bytes: diskBytes(profile)) : .absent
  }

  // MARK: - Download

  func download(_ profile: ModelProfile, completion: ((Bool) -> Void)? = nil) {
    guard downloads[profile.id] == nil else { return }
    if isComplete(profile) {
      statuses[profile.id] = .ready(bytes: diskBytes(profile))
      completion?(true)
      return
    }

    let download = Download(completion: completion)
    downloads[profile.id] = download
    statuses[profile.id] = .downloading(
      progress: 0, completed: diskBytes(profile), total: profile.bytes)
    startPolling(profile)

    let assets = profile.assets
    let env = environment
    DispatchQueue.global(qos: .userInitiated).async {
      var ok = true
      for asset in assets {
        if download.isCancelled { ok = false; break }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["hf", "download", asset.repo, asset.file]
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard download.adopt(process) else { ok = false; break }
        do {
          try process.run()
        } catch {
          ok = false
          break
        }
        // Catch a cancel that landed in the window between adopt() and run().
        if download.isCancelled { process.terminate(); ok = false; break }
        process.waitUntilExit()
        if download.isCancelled || process.terminationStatus != 0 { ok = false; break }
      }
      let succeeded = ok
      Task { @MainActor in
        self.finishDownload(profile, succeeded: succeeded, download: download)
      }
    }
  }

  func cancel(_ profile: ModelProfile) {
    downloads[profile.id]?.cancel()
  }

  /// Cancel every in-flight download (used on quit).
  func cancelAll() {
    for download in downloads.values { download.cancel() }
  }

  func isDownloading(_ profile: ModelProfile) -> Bool {
    downloads[profile.id] != nil
  }

  private func finishDownload(_ profile: ModelProfile, succeeded: Bool, download: Download) {
    guard downloads[profile.id] === download else { return }
    downloads[profile.id] = nil
    stopPolling(profile)

    if isComplete(profile) {
      statuses[profile.id] = .ready(bytes: diskBytes(profile))
      download.completion?(true)
    } else if download.isCancelled {
      statuses[profile.id] = .absent
      download.completion?(false)
    } else {
      statuses[profile.id] = .failed(succeeded ? "Download incomplete" : "Download failed")
      download.completion?(false)
    }
  }

  private func startPolling(_ profile: ModelProfile) {
    stopPolling(profile)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateProgress(profile) }
    }
    pollTimers[profile.id] = timer
  }

  private func stopPolling(_ profile: ModelProfile) {
    pollTimers[profile.id]?.invalidate()
    pollTimers[profile.id] = nil
  }

  private func updateProgress(_ profile: ModelProfile) {
    guard downloads[profile.id] != nil else { return }
    let total = profile.bytes
    // Walk the cache off the main actor; publish the result back on it.
    DispatchQueue.global(qos: .utility).async {
      let completed = self.diskBytes(profile)
      Task { @MainActor in
        guard self.downloads[profile.id] != nil else { return }
        let progress = total > 0 ? min(0.999, Double(completed) / Double(total)) : 0
        self.statuses[profile.id] = .downloading(progress: progress, completed: completed, total: total)
      }
    }
  }

  // MARK: - Delete

  func delete(_ profile: ModelProfile) {
    cancel(profile)
    statuses[profile.id] = .absent
    let assets = profile.assets
    DispatchQueue.global(qos: .utility).async {
      for asset in assets { self.removeSnapshotLinks(asset) }
      for repo in Set(assets.map(\.repo)) { self.garbageCollectRepo(repo) }
      Task { @MainActor in self.refresh(profile) }
    }
  }

  /// Remove the snapshot symlink(s) for an asset across all revisions — never the blob
  /// directly, since blobs are content-addressed and can be shared by other files.
  nonisolated private func removeSnapshotLinks(_ asset: ModelAsset) {
    let fm = FileManager.default
    let snapshots = repoURL(asset.repo).appendingPathComponent("snapshots")
    guard let revisions = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
    else { return }
    for revision in revisions {
      try? fm.removeItem(at: revision.appendingPathComponent(asset.file))
    }
  }

  /// Delete blobs no longer referenced by any snapshot symlink, then drop the repo folder
  /// once no real blobs remain (also clearing leftover `*.incomplete` partials).
  nonisolated private func garbageCollectRepo(_ repo: String) {
    let fm = FileManager.default
    let repoDir = repoURL(repo)
    let blobsDir = repoDir.appendingPathComponent("blobs")
    let referenced = referencedBlobPaths(repo)

    if let blobs = try? fm.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil) {
      for blob in blobs where !blob.lastPathComponent.hasSuffix(".incomplete") {
        if !referenced.contains(blob.standardizedFileURL.path) {
          try? fm.removeItem(at: blob)
        }
      }
    }

    let remaining = (try? fm.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil)) ?? []
    if remaining.allSatisfy({ $0.lastPathComponent.hasSuffix(".incomplete") }) {
      try? fm.removeItem(at: repoDir)
    }
  }

  /// Blob paths still referenced by a remaining snapshot symlink in the repo.
  nonisolated private func referencedBlobPaths(_ repo: String) -> Set<String> {
    let fm = FileManager.default
    let snapshots = repoURL(repo).appendingPathComponent("snapshots")
    var paths = Set<String>()
    guard let enumerator = fm.enumerator(
      at: snapshots, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return paths }
    for case let url as URL in enumerator {
      let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
      if isLink, let blob = Self.blobURL(forLink: url) {
        paths.insert(blob.standardizedFileURL.path)
      }
    }
    return paths
  }

  // MARK: - Cache helpers

  nonisolated private func repoURL(_ repo: String) -> URL {
    let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
    return hubURL.appendingPathComponent(folder)
  }

  /// Total bytes currently stored in the blobs directories backing a profile's repos.
  nonisolated private func diskBytes(_ profile: ModelProfile) -> Int64 {
    var total: Int64 = 0
    for repo in Set(profile.assets.map(\.repo)) {
      let blobs = repoURL(repo).appendingPathComponent("blobs")
      guard let entries = try? FileManager.default.contentsOfDirectory(
        at: blobs, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
      for entry in entries {
        let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        total += Int64(size)
      }
    }
    return total
  }

  nonisolated private static func blobURL(forLink link: URL) -> URL? {
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    else { return nil }
    return URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
      .standardizedFileURL
  }

  private static func resolveHubURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let hub = env["HF_HUB_CACHE"], !hub.isEmpty {
      return URL(fileURLWithPath: hub, isDirectory: true)
    }
    if let home = env["HF_HOME"], !home.isEmpty {
      return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub")
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
  }

  private static func makeEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let homebrew = "/opt/homebrew/bin:/usr/local/bin"
    env["PATH"] = "\(homebrew):\(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
    return env
  }
}

/// A single in-flight download. The backing `hf` process can change as assets are
/// fetched sequentially; cancellation is safe from any thread.
private final class Download: @unchecked Sendable {
  let completion: ((Bool) -> Void)?
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  init(completion: ((Bool) -> Void)?) {
    self.completion = completion
  }

  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }

  /// Adopt the next process. Returns false (and does not adopt) if already cancelled.
  func adopt(_ next: Process) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if cancelled { return false }
    process = next
    return true
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let running = process
    lock.unlock()
    // Only terminate a launched process; terminating an unlaunched one raises.
    // A cancel that lands before launch is caught by the post-run() check.
    if running?.isRunning == true { running?.terminate() }
  }
}
