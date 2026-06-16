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
/// Switching the active profile while the server runs stops it and relaunches with the
/// new profile's parameters. Quitting the app terminates the server (see `App`).
@MainActor
final class ServerController: ObservableObject {
  static let shared = ServerController()

  let store = ModelStore()

  @Published private(set) var state: ServerState = .stopped
  @Published private(set) var message = ""

  @Published var selectedProfileID: String {
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

  // MARK: - Selection

  func selectProfile(_ id: String) {
    guard id != selectedProfileID, Catalog.profile(id: id) != nil else { return }
    selectedProfileID = id
    if state.isActive { restart() }
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
        guard self.selectedProfileID == profile.id,
              self.state.isStarting, self.process == nil else { return }
        if ready { self.launch(profile) } else { self.fail("Couldn’t download \(profile.name)") }
      }
      return
    }

    launch(profile)
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

  private func launch(_ profile: ModelProfile) {
    guard let weights = store.localURL(for: profile.weights)?.path else {
      fail("Model files missing for \(profile.name)")
      return
    }

    // `-c 0` uses each model's full trained context; `--jinja` uses the model's own
    // embedded chat template for the most faithful tool-calling / reasoning handling.
    var arguments = ["llama-server", "-m", weights, "-c", "0", "--jinja"]
    if let draft = profile.draft {
      guard let draftPath = store.localURL(for: draft)?.path else {
        fail("Draft model missing for \(profile.name)")
        return
      }
      arguments += ["-md", draftPath]
    }
    arguments += profile.extraArguments
    arguments += ["-a", "local", "--host", host, "--port", String(port), "--no-ui"]

    do {
      let log = try Self.makeLogFile()
      let handle = try FileHandle(forWritingTo: log)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = arguments
      process.environment = environment
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
      self.message = "Loading \(profile.name)…"
      pollUntilReady()
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func handleTermination(_ finished: Process) {
    guard finished === process else { return }
    readinessTimer?.invalidate()
    readinessTimer = nil
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
  }

  // MARK: - Failure & shutdown

  private func fail(_ text: String) {
    readinessTimer?.invalidate()
    readinessTimer = nil
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
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  // MARK: - Helpers

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
