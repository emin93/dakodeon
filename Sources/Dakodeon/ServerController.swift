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

enum RouterModelState: String, Equatable {
  case loaded
  case loading
  case sleeping
  case failed

  var isMemoryResident: Bool {
    self == .loaded || self == .loading
  }
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

  /// The model the router most recently has active (loaded, loading, or sleeping), or nil
  /// when every known model is unloaded. Clients drive this by sending a `model` id per request.
  @Published private(set) var activeModelID: String?
  @Published private(set) var activeModelState: RouterModelState?
  @Published private(set) var activeModelDiagnostic: String?
  @Published private(set) var modelDiagnostics: [String: String] = [:]

  /// The fallback profile used for start-triggered downloads. Not a user-facing selector: it
  /// tracks the last model the router loaded so a first launch has a sensible default asset.
  @Published private(set) var selectedProfileID: String {
    didSet { UserDefaults.standard.set(selectedProfileID, forKey: Self.selectionKey) }
  }

  private(set) var logURL: URL?

  let host = "127.0.0.1"
  let port = 8080
  var endpoint: String { "http://\(host):\(port)/v1" }

  private static let selectionKey = "selectedProfileID"
  private let routerIdleSleepSeconds = 300
  private let environment = ServerController.makeEnvironment()
  private let routerSession = ServerController.makeRouterSession()
  private var process: Process?
  private var logHandle: FileHandle?
  private var readinessTimer: Timer?
  private var routerSyncTimer: Timer?
  private var readinessAttempts = 0
  private var readinessCheckInFlight = false
  private var routerSyncInFlight = false
  private var routerSyncFailures = 0
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
    readinessCheckInFlight = false
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

  func download(_ profile: ModelProfile) {
    store.download(profile) { [weak self] ready in
      guard let self, ready, self.state.isRunning else { return }
      self.refreshRouterCatalog()
    }
  }

  func delete(_ profile: ModelProfile) {
    guard activeModelID != profile.id else { return }
    let shouldResume = state.isRunning
    if selectedProfileID == profile.id, let replacement = replacementProfileID(excluding: profile.id) {
      selectedProfileID = replacement
    }

    store.delete(profile) { [weak self] in
      guard let self, shouldResume else { return }
      if Catalog.profiles.contains(where: { self.store.isComplete($0) }) {
        self.refreshRouterCatalog()
      } else {
        self.stop()
      }
    }
  }

  func modelDiagnostic(for profile: ModelProfile) -> String? {
    modelDiagnostics[profile.id]
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
        "--models-autoload",
        "--sleep-idle-seconds", String(routerIdleSleepSeconds),
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
    readinessCheckInFlight = false
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
    guard let process, process.isRunning, !readinessCheckInFlight else { return }
    readinessAttempts += 1
    if readinessAttempts > 180 {
      fail("Timed out waiting for llama-server")
      return
    }

    readinessCheckInFlight = true
    let url = URL(string: "http://\(host):\(port)/models")!
    routerSession.dataTask(with: url) { [weak self] _, response, _ in
      let ready = (response as? HTTPURLResponse)
        .map { (200..<300).contains($0.statusCode) } ?? false
      Task { @MainActor in
        guard let self else { return }
        self.readinessCheckInFlight = false
        if ready { self.markRunning() }
      }
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
    routerSyncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.syncRouterActiveModel() }
    }
  }

  private func stopRouterSync() {
    routerSyncTimer?.invalidate()
    routerSyncTimer = nil
    routerSyncInFlight = false
  }

  /// Tear down router bookkeeping: stop the sync poll and clear the active-model mirror.
  /// Called from every path that ends the server process.
  private func resetRouterState() {
    stopRouterSync()
    activeModelID = nil
    activeModelState = nil
    activeModelDiagnostic = nil
    modelDiagnostics = [:]
    routerSyncFailures = 0
  }

  /// Poll the router for the active model and mirror it into `activeModelID`. Clients
  /// decide which model is loaded by the `model` id they send; Dakodeon keeps the
  /// router alive and lets llama-server autoload/sleep the model process.
  private func syncRouterActiveModel() {
    guard process?.isRunning == true, !routerSyncInFlight else { return }
    routerSyncInFlight = true
    let url = URL(string: "http://\(host):\(port)/models")!
    routerSession.dataTask(with: url) { [weak self] data, response, _ in
      guard let data,
            let status = (response as? HTTPURLResponse)?.statusCode,
            (200..<300).contains(status),
            let payload = try? JSONDecoder().decode(RouterModelsResponse.self, from: data)
      else {
        Task { @MainActor in self?.handleRouterSyncFailure() }
        return
      }

      let known = Set(Catalog.profiles.map(\.id))
      let models = payload.data.filter { known.contains($0.id) }
      let activeModel = models.first { $0.routerState == .loaded }
        ?? models.first { $0.routerState == .loading }
        ?? models.first { $0.routerState == .sleeping }
        ?? models.first { $0.routerState == .failed }
      let diagnostics = Dictionary(
        uniqueKeysWithValues: models.compactMap { model in
          model.diagnostic.map { (model.id, $0) }
        }
      )
      Task { @MainActor in
        guard let self else { return }
        self.routerSyncInFlight = false
        guard self.process?.isRunning == true else { return }
        if self.routerSyncFailures > 0 {
          self.routerSyncFailures = 0
          self.message = "Serving \(self.endpoint)"
        }
        if self.activeModelID != activeModel?.id {
          self.activeModelID = activeModel?.id
        }
        if self.activeModelState != activeModel?.routerState {
          self.activeModelState = activeModel?.routerState
        }
        if self.activeModelDiagnostic != activeModel?.diagnostic {
          self.activeModelDiagnostic = activeModel?.diagnostic
        }
        if self.modelDiagnostics != diagnostics {
          self.modelDiagnostics = diagnostics
        }
        if let diagnostic = diagnostics.values.sorted().first {
          self.message = diagnostic
        } else if self.message != "Serving \(self.endpoint)" {
          self.message = "Serving \(self.endpoint)"
        }
        // Remember the last fully-loaded model so first-run downloads stay useful.
        if activeModel?.routerState == .loaded,
           let loaded = activeModel?.id,
           self.selectedProfileID != loaded {
          self.selectedProfileID = loaded
        }
      }
    }.resume()
  }

  private func refreshRouterCatalog() {
    guard state.isRunning, process?.isRunning == true else { return }
    do {
      let profiles = Catalog.profiles.filter { store.isComplete($0) }
      guard !profiles.isEmpty else {
        stop()
        return
      }
      _ = try writeRouterPreset(profiles)
      reloadRouterModels()
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func reloadRouterModels() {
    guard process?.isRunning == true else { return }
    var components = URLComponents(string: "http://\(host):\(port)/models")!
    components.queryItems = [URLQueryItem(name: "reload", value: "1")]
    routerSession.dataTask(with: components.url!) { [weak self] _, response, _ in
      let reloaded = (response as? HTTPURLResponse)
        .map { (200..<300).contains($0.statusCode) } ?? false
      Task { @MainActor in
        guard let self else { return }
        if reloaded {
          self.syncRouterActiveModel()
        } else {
          self.handleRouterSyncFailure()
        }
      }
    }.resume()
  }

  private func handleRouterSyncFailure() {
    routerSyncInFlight = false
    guard process?.isRunning == true, state.isRunning else { return }
    routerSyncFailures += 1
    if routerSyncFailures >= 5 {
      fail("llama-server health check failed")
    } else {
      message = "Router health check failed"
    }
  }

  func unloadActiveModel() {
    guard let activeModelID else { return }
    unloadModel(id: activeModelID)
  }

  func unloadModel(id: String) {
    guard process?.isRunning == true else { return }
    var request = URLRequest(url: URL(string: "http://\(host):\(port)/models/unload")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(RouterModelRequest(model: id))

    routerSession.dataTask(with: request) { [weak self] _, response, _ in
      guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
      else { return }
      Task { @MainActor in self?.syncRouterActiveModel() }
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
        "load-on-startup = false",
        "stop-timeout = 3",
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

  private func replacementProfileID(excluding removedID: String) -> String? {
    Catalog.profiles.first {
      $0.id != removedID && store.isComplete($0)
    }?.id ?? Catalog.profiles.first {
      $0.id != removedID
    }?.id
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

  private static func makeRouterSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 4
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }
}

private struct RouterModelRequest: Encodable {
  let model: String
}

private struct RouterModelsResponse: Decodable {
  let data: [RouterModel]
}

private struct RouterModel: Decodable {
  let id: String
  let status: RouterStatus?

  var routerState: RouterModelState? {
    if status?.failed == true { return .failed }
    guard let value = status?.value else { return nil }
    return RouterModelState(rawValue: value)
  }

  var diagnostic: String? {
    guard routerState == .failed else { return nil }
    if let exitCode = status?.exitCode {
      return "\(id) failed to load (exit \(exitCode))"
    }
    return "\(id) failed to load"
  }
}

private struct RouterStatus: Decodable {
  let value: String
  let failed: Bool?
  let exitCode: Int?

  private enum CodingKeys: String, CodingKey {
    case value
    case failed
    case exitCode = "exit_code"
  }
}
