import AppKit
import Foundation

enum ServerState: Equatable {
  case stopped
  case starting
  case running
  case failed(String)

  var isActive: Bool { self == .running || self == .starting }
  var isRunning: Bool { self == .running }
  var isStarting: Bool { self == .starting }
}

/// Owns the `llama-server` process lifecycle and the selected model profile.
///
/// Launches llama-server in router mode with curated model presets. Requests from
/// clients such as OpenCode select the active profile through the JSON `model` field.
/// Quitting the app terminates the server (see `App`).
@MainActor
final class ServerController: ObservableObject {
  static let shared = ServerController()

  let store = ModelStore()

  @Published private(set) var state: ServerState = .stopped
  @Published private(set) var message = ""

  /// The model the router currently has loaded (from `/v1/models`), or nil when none is.
  /// Clients such as OpenCode drive this by sending a `model` id per request.
  @Published private(set) var activeModelID: String?

  /// The profile preloaded when the server starts. Not a user-facing selector: it tracks
  /// the last model the router had loaded so the next launch resumes it.
  @Published private(set) var selectedProfileID: String {
    didSet { UserDefaults.standard.set(selectedProfileID, forKey: Self.selectionKey) }
  }

  private(set) var logURL: URL?

  let host = "127.0.0.1"
  let port = 8080
  var endpoint: String { "http://\(host):\(port)/v1" }

  private static let selectionKey = "selectedProfileID"
  private let environment = ServerController.makeEnvironment()
  private var process: Process?
  private var logHandle: FileHandle?
  private var readinessTimer: Timer?
  private var routerSyncTimer: Timer?
  private var readinessAttempts = 0
  private var stoppingIntentionally = false
  private var pendingRestart = false
  private var activeDownloadProfileID: String?

  private init() {
    let saved = UserDefaults.standard.string(forKey: Self.selectionKey) ?? ""
    self.selectedProfileID = Catalog.profile(id: saved) != nil ? saved
      : (Catalog.profiles.first?.id ?? "")
    self.message = "Idle"
  }

  var selectedProfile: ModelProfile? { Catalog.profile(id: selectedProfileID) }

  /// Status of the currently selected profile (drives the menu download UI).
  var selectedStatus: ModelStatus {
    selectedProfile.map { store.status(for: $0) } ?? .absent
  }

  // MARK: - Run control

  func toggle() {
    state.isActive ? stop() : start()
  }

  func start() {
    guard let profile = selectedProfile, process == nil else { return }
    state = .starting

    guard store.isComplete(profile) else {
      message = "Downloading \(profile.name)…"
      activeDownloadProfileID = profile.id
      store.download(profile) { [weak self] ready in
        guard let self else { return }
        if self.activeDownloadProfileID == profile.id { self.activeDownloadProfileID = nil }
        guard self.state.isStarting, self.process == nil else { return }
        if ready { self.launchRouter() } else { self.fail("Couldn’t download \(profile.name)") }
      }
      return
    }

    launchRouter()
  }

  func stop() {
    performStop(forRestart: false)
  }

  private func restart() {
    performStop(forRestart: true)
  }

  private func performStop(forRestart: Bool) {
    // Coalesce overlapping transitions: if a process is already terminating, just record
    // whether a relaunch should follow instead of signalling it a second time.
    if process != nil && stoppingIntentionally {
      pendingRestart = forRestart
      return
    }

    pendingRestart = forRestart
    readinessTimer?.invalidate()
    readinessTimer = nil
    stopRouterSync()

    // Cancel a start-triggered download for whichever profile is actually downloading.
    if let id = activeDownloadProfileID, let profile = Catalog.profile(id: id) {
      store.cancel(profile)
      activeDownloadProfileID = nil
    }

    guard let process else {
      finishStopped()
      return
    }

    stoppingIntentionally = true
    message = "Stopping…"
    process.terminate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
      if process?.isRunning == true { kill(process!.processIdentifier, SIGKILL) }
    }
  }

  /// Cancel an in-flight download. A server-initiated download is routed through stop()
  /// so the controller returns cleanly to stopped rather than failed.
  func cancelDownload(_ profile: ModelProfile) {
    if profile.id == activeDownloadProfileID && state.isStarting {
      stop()
    } else {
      store.cancel(profile)
    }
  }

  func openLogs() {
    guard let logURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([logURL])
  }

  // MARK: - Launch

  private func launchRouter() {
    let profiles = Catalog.profiles.filter { store.isComplete($0) }
    guard !profiles.isEmpty else {
      fail("No downloaded models")
      return
    }

    do {
      let preset = try writeRouterPreset(profiles)
      let log = try Self.makeLogFile()
      let handle = try FileHandle(forWritingTo: log)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "llama-server",
        "--models-preset", preset.path,
        "--models-max", "1",
        "--host", host,
        "--port", String(port),
        "--no-ui",
      ]
      process.environment = routerEnvironment()
      process.standardOutput = handle
      process.standardError = handle
      process.terminationHandler = { [weak self] finished in
        Task { @MainActor in self?.handleTermination(finished) }
      }
      try process.run()

      self.process = process
      self.logHandle = handle
      self.logURL = log
      self.stoppingIntentionally = false
      self.message = "Starting router…"
      pollUntilReady()
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func handleTermination(_ finished: Process) {
    guard finished === process else { return }
    readinessTimer?.invalidate()
    readinessTimer = nil
    resetRouterState()
    process = nil
    activeDownloadProfileID = nil
    closeLog()

    let intended = stoppingIntentionally
    stoppingIntentionally = false

    if pendingRestart {
      pendingRestart = false
      state = .stopped
      message = "Restarting…"
      start()
      return
    }

    if intended {
      finishStopped()
    } else {
      state = .failed("llama-server stopped")
      message = "Stopped unexpectedly — check Logs"
    }
  }

  private func finishStopped() {
    state = .stopped
    message = "Idle"
    resetRouterState()
    if pendingRestart {
      pendingRestart = false
      start()
    }
  }

  // MARK: - Readiness

  private func pollUntilReady() {
    readinessAttempts = 0
    readinessTimer?.invalidate()
    readinessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkReadiness() }
    }
  }

  private func checkReadiness() {
    guard let process, process.isRunning else { return }
    readinessAttempts += 1
    if readinessAttempts > 180 {
      fail("Timed out waiting for llama-server")
      return
    }

    let url = URL(string: "\(endpoint)/models")!
    URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
      guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
      else { return }
      Task { @MainActor in self?.markRunning() }
    }.resume()
  }

  private func markRunning() {
    // Ignore a late readiness response that lands after a stop was requested.
    guard state.isStarting, !stoppingIntentionally, process != nil else { return }
    readinessTimer?.invalidate()
    readinessTimer = nil
    state = .running
    message = "Serving \(endpoint)"
    startRouterSync()
  }

  // MARK: - Router sync

  private func startRouterSync() {
    stopRouterSync()
    syncRouterActiveModel()
    routerSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.syncRouterActiveModel() }
    }
  }

  private func stopRouterSync() {
    routerSyncTimer?.invalidate()
    routerSyncTimer = nil
  }

  /// Tear down router bookkeeping: stop the sync poll and clear the active-model mirror.
  /// Called from every path that ends the server process.
  private func resetRouterState() {
    stopRouterSync()
    activeModelID = nil
  }

  /// Poll the router for the loaded model and mirror it into `activeModelID`. Clients
  /// (OpenCode, etc.) decide which model is loaded by the `model` id they send; Dakodeon
  /// only reflects it and remembers the last loaded model as the next startup profile.
  private func syncRouterActiveModel() {
    guard process?.isRunning == true else { return }
    let url = URL(string: "\(endpoint)/models")!
    URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
      guard let data,
            let status = (response as? HTTPURLResponse)?.statusCode,
            (200..<300).contains(status),
            let payload = try? JSONDecoder().decode(RouterModelsResponse.self, from: data)
      else { return }

      let known = Set(Catalog.profiles.map(\.id))
      let models = payload.data.filter { known.contains($0.id) }
      let loaded = models.first { $0.status?.value == "loaded" }?.id
      let active = loaded ?? models.first { $0.status?.value == "loading" }?.id
      Task { @MainActor in
        guard let self, self.process?.isRunning == true else { return }
        self.activeModelID = active
        // Remember the last fully-loaded model so the next launch preloads it.
        if let loaded, self.selectedProfileID != loaded { self.selectedProfileID = loaded }
      }
    }.resume()
  }

  // MARK: - Failure & shutdown

  private func fail(_ text: String) {
    readinessTimer?.invalidate()
    readinessTimer = nil
    resetRouterState()
    pendingRestart = false
    activeDownloadProfileID = nil

    // Terminate the process and force-kill it if it ignores SIGTERM. The closure keeps
    // `dying` alive long enough to escalate; we detach `process` first so the
    // terminationHandler can't overwrite the .failed state.
    if let dying = process, dying.isRunning {
      dying.terminate()
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        if dying.isRunning { kill(dying.processIdentifier, SIGKILL) }
      }
    }
    process = nil
    stoppingIntentionally = false
    closeLog()
    state = .failed(text)
    message = text
  }

  /// Synchronously stop the server. Called from the app's terminate hook.
  func terminateForQuit() {
    store.cancelAll()
    readinessTimer?.invalidate()
    readinessTimer = nil
    resetRouterState()
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  // MARK: - Helpers

  private func writeRouterPreset(_ profiles: [ModelProfile]) throws -> URL {
    let directory = try Self.applicationSupportDirectory()
      .appendingPathComponent("Router", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("models.ini")

    var lines: [String] = []
    for profile in profiles {
      guard let weights = store.localURL(for: profile.weights)?.path else {
        throw Self.error("Model files missing for \(profile.name)")
      }

      lines += [
        "[\(profile.id)]",
        "load-on-startup = \(profile.id == selectedProfileID ? "true" : "false")",
        "model = \(weights)",
      ]

      if let draft = profile.draft {
        guard let draftPath = store.localURL(for: draft)?.path else {
          throw Self.error("Draft model missing for \(profile.name)")
        }
        lines.append("model-draft = \(draftPath)")
      }

      if let mmproj = profile.mmproj {
        guard let mmprojPath = store.localURL(for: mmproj)?.path else {
          throw Self.error("Vision projector missing for \(profile.name)")
        }
        lines.append("mmproj = \(mmprojPath)")
      }

      for (key, value) in Self.routerPresetArguments(profile.extraArguments) {
        lines.append("\(key) = \(value)")
      }
      lines.append("")
    }

    try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  private func routerEnvironment() -> [String: String] {
    var env = environment
    if let directory = try? Self.applicationSupportDirectory()
      .appendingPathComponent("LlamaCache", isDirectory: true) {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      env["LLAMA_CACHE"] = directory.path
    }
    return env
  }

  private static func routerPresetArguments(_ arguments: [String]) -> [(String, String)] {
    var result: [(String, String)] = []
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      guard flag.hasPrefix("-") else {
        index += 1
        continue
      }

      let key = routerPresetKey(flag)
      let next = index + 1 < arguments.count ? arguments[index + 1] : nil
      if let next, !next.hasPrefix("-") {
        result.append((key, next))
        index += 2
      } else {
        result.append((key, "true"))
        index += 1
      }
    }
    return result
  }

  private static func routerPresetKey(_ flag: String) -> String {
    switch flag {
    case "-fa", "--flash-attn":
      return "flash-attn"
    case "-ngl", "--n-gpu-layers":
      return "n-gpu-layers"
    case "-md", "--model-draft":
      return "model-draft"
    default:
      return flag.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
  }

  private static func applicationSupportDirectory() throws -> URL {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dakodeon", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: "Dakodeon", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func closeLog() {
    try? logHandle?.close()
    logHandle = nil
  }

  private static func makeLogFile() throws -> URL {
    let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Dakodeon", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let file = directory.appendingPathComponent("llama-server-\(formatter.string(from: Date())).log")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    return file
  }

  private static func makeEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let homebrew = "/opt/homebrew/bin:/usr/local/bin"
    env["PATH"] = "\(homebrew):\(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
    return env
  }
}

private struct RouterModelsResponse: Decodable {
  let data: [RouterModel]
}

private struct RouterModel: Decodable {
  let id: String
  let status: RouterStatus?
}

private struct RouterStatus: Decodable {
  let value: String
}
