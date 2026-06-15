import AppKit
import Foundation
import SwiftUI

@main
struct DakodeonApp: App {
  @StateObject private var server = LlamaServerController()

  var body: some Scene {
    MenuBarExtra {
      DakodeonMenu(server: server)
    } label: {
      Image(nsImage: DakodeonImages.statusBarIcon())
    }
    .menuBarExtraStyle(.window)
  }
}

private struct DakodeonMenu: View {
  @ObservedObject var server: LlamaServerController

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(nsImage: DakodeonImages.appIcon())
          .resizable()
          .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: 2) {
          Text("Dakodeon")
            .font(.headline)
          HStack(spacing: 6) {
            Circle()
              .fill(server.state.tint)
              .frame(width: 7, height: 7)
            Text(server.state.title)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Model")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("Model", selection: $server.selectedModelID) {
          ForEach(server.models) { model in
            Text(model.name).tag(model.id)
          }
        }
        .labelsHidden()
        .disabled(server.state.isBusy)
        .frame(maxWidth: .infinity)
      }

      Button {
        server.toggle()
      } label: {
        Label(server.state.isActive ? "Stop Server" : "Start Server",
              systemImage: server.state.isActive ? "stop.fill" : "play.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(server.state.isBusy)

      Text(server.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      Divider()

      HStack {
        Button("Logs") {
          server.openLogs()
        }
        .disabled(server.logURL == nil)

        Spacer()

        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
      .buttonStyle(.borderless)
      .font(.caption)
    }
    .padding(16)
    .frame(width: 310)
  }
}

private enum ServerState: Equatable {
  case stopped
  case starting
  case running
  case failed(String)

  var title: String {
    switch self {
    case .stopped: "Stopped"
    case .starting: "Starting"
    case .running: "Running"
    case .failed: "Needs attention"
    }
  }

  var tint: Color {
    switch self {
    case .stopped: .secondary
    case .starting: .orange
    case .running: .green
    case .failed: .red
    }
  }

  var isActive: Bool {
    self == .running || self == .starting
  }

  var isBusy: Bool {
    self == .starting
  }
}

private struct SupportedModel: Identifiable, Hashable {
  let id: String
  let name: String
  let huggingFaceModel: String
  let draft: DraftModel?
}

private struct DraftModel: Hashable {
  let repository: String
  let file: String
}

@MainActor
private final class LlamaServerController: ObservableObject {
  @Published var models = SupportedModel.bundled
  @Published var state: ServerState = .stopped
  @Published var message = "Stopped"
  @Published var logURL: URL?

  @Published var selectedModelID: String {
    didSet { defaults.set(selectedModelID, forKey: Defaults.selectedModelID) }
  }

  private let defaults = UserDefaults.standard
  private let host = "127.0.0.1"
  private let port = 8080
  private var process: Process?
  private var logHandle: FileHandle?
  private var readinessTimer: Timer?
  private var readinessAttempts = 0

  init() {
    self.selectedModelID = defaults.string(forKey: Defaults.selectedModelID) ?? ""
    if !models.contains(where: { $0.id == selectedModelID }) {
      selectedModelID = models.first?.id ?? ""
    }
    message = "Ready on http://\(host):\(port)/v1"
  }

  func toggle() {
    state.isActive ? stop() : start()
  }

  func start() {
    guard let model = selectedModel else { return }
    guard process == nil else { return }

    state = .starting
    message = "Preparing \(model.name)"

    DispatchQueue.global(qos: .userInitiated).async { [host, port] in
      do {
        let launch = try LlamaLaunchPlan(model: model, host: host, port: port)
        DispatchQueue.main.async { [weak self] in
          self?.launch(launch)
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.fail(error.localizedDescription)
        }
      }
    }
  }

  func stop() {
    readinessTimer?.invalidate()
    readinessTimer = nil

    guard let process else {
      state = .stopped
      message = "Stopped"
      return
    }

    message = "Stopping"
    process.terminate()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      if process.isRunning {
        process.interrupt()
      }
    }
  }

  func openLogs() {
    guard let logURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([logURL])
  }

  private var selectedModel: SupportedModel? {
    models.first { $0.id == selectedModelID }
  }

  private func launch(_ launch: LlamaLaunchPlan) {
    do {
      let log = try Self.makeLogFile()
      let handle = try FileHandle(forWritingTo: log)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = launch.arguments
      process.environment = launch.environment
      process.standardOutput = handle
      process.standardError = handle
      process.terminationHandler = { [weak self, weak process] _ in
        DispatchQueue.main.async {
          guard let self, let process, self.process === process else { return }
          self.finishTerminatedProcess(process)
        }
      }

      try process.run()

      self.process = process
      self.logHandle = handle
      self.logURL = log
      self.message = "Starting \(launch.modelName)"
      pollUntilReady()
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func pollUntilReady() {
    readinessAttempts = 0
    readinessTimer?.invalidate()
    readinessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.checkReadiness()
      }
    }
  }

  private func checkReadiness() {
    guard let process, process.isRunning else {
      fail("llama-server exited during startup")
      return
    }

    readinessAttempts += 1
    if readinessAttempts > 120 {
      stop()
      fail("Timed out waiting for llama-server")
      return
    }

    let url = URL(string: "http://\(host):\(port)/v1/models")!
    URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
      guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
      guard (200..<300).contains(status) else { return }
      DispatchQueue.main.async {
        self?.readinessTimer?.invalidate()
        self?.readinessTimer = nil
        self?.state = .running
        self?.message = "Serving http://\(self?.host ?? "127.0.0.1"):\(self?.port ?? 8080)/v1"
      }
    }.resume()
  }

  private func finishTerminatedProcess(_ process: Process) {
    readinessTimer?.invalidate()
    readinessTimer = nil
    self.process = nil
    closeLog()
    state = process.terminationStatus == 0 ? .stopped : .failed("llama-server exited")
    message = process.terminationStatus == 0 ? "Stopped" : "llama-server exited; check logs"
  }

  private func fail(_ text: String) {
    readinessTimer?.invalidate()
    readinessTimer = nil
    process?.terminate()
    state = .failed(text)
    message = text
    closeLog()
    process = nil
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
}

private struct LlamaLaunchPlan {
  let modelName: String
  let arguments: [String]
  let environment: [String: String]

  init(model: SupportedModel, host: String, port: Int) throws {
    let environment = Self.environment()
    var arguments = [
      "llama-server",
      "-hf", model.huggingFaceModel.removingPrefix("hf:")
    ]

    if let draft = model.draft {
      let draftPath = try Self.capture(
        ["hf", "download", draft.repository, draft.file, "--quiet"],
        environment: environment
      )
      arguments += [
        "--model-draft", draftPath.trimmingCharacters(in: .whitespacesAndNewlines),
        "--spec-type", "draft-mtp",
        "--spec-draft-n-max", "4",
        "--n-gpu-layers-draft", "all"
      ]
    }

    arguments += [
      "--alias", "local",
      "--host", host,
      "--port", String(port),
      "--no-ui"
    ]

    self.modelName = model.name
    self.arguments = arguments
    self.environment = environment
  }

  private static func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let homebrew = "/opt/homebrew/bin:/usr/local/bin"
    env["PATH"] = "\(homebrew):\(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")"
    return env
  }

  private static func capture(_ arguments: [String], environment: [String: String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw RuntimeError(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output
  }
}

private extension SupportedModel {
  static let bundled = [
    SupportedModel(
      id: "gemma-4-12b-coder",
      name: "Gemma4-12B-Coder",
      huggingFaceModel: "yuxinlu1/gemma-4-12B-coder-fable5-composer2.5-v1-GGUF:Q8_0",
      draft: DraftModel(
        repository: "yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF",
        file: "MTP/gemma-4-12B-it-MTP-Q8_0.gguf"
      )
    )
  ]
}

private enum DakodeonImages {
  static func statusBarIcon() -> NSImage {
    let image = appIcon()
    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    return image
  }

  static func appIcon() -> NSImage {
    if let image = NSImage(named: "DakodeonIcon") {
      return image
    }
    if let url = Bundle.main.url(forResource: "DakodeonIcon", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
      return image
    }
    return fallbackIcon()
  }

  private static func fallbackIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.labelColor.setStroke()
    let path = NSBezierPath(roundedRect: NSRect(x: 14, y: 10, width: 36, height: 44),
                            xRadius: 18,
                            yRadius: 18)
    path.lineWidth = 6
    path.stroke()
    NSColor.labelColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: 24, y: 22, width: 18, height: 5),
                 xRadius: 2,
                 yRadius: 2).fill()
    NSBezierPath(roundedRect: NSRect(x: 24, y: 34, width: 18, height: 5),
                 xRadius: 2,
                 yRadius: 2).fill()
    image.unlockFocus()
    image.isTemplate = true
    return image
  }
}

private enum Defaults {
  static let selectedModelID = "selectedModelID"
}

private struct RuntimeError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message.isEmpty ? "Command failed" : message
  }

  var errorDescription: String? { message }
}

private extension String {
  func removingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}
