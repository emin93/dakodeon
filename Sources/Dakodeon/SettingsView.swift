import AppKit
import SwiftUI

/// The Settings window: model management, server info, and about.
struct SettingsView: View {
  @ObservedObject var server: ServerController
  @ObservedObject var store: ModelStore

  var body: some View {
    Form {
      Section {
        ForEach(Catalog.profiles) { profile in
          ModelRow(profile: profile, server: server, store: store)
        }
      } header: {
        Text("Models")
      } footer: {
        Text("Models are downloaded to the shared Hugging Face cache via the `hf` CLI.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("Server") {
        LabeledContent("Endpoint") {
          HStack(spacing: 6) {
            Text(server.endpoint).font(.system(size: 12, design: .monospaced))
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(server.endpoint, forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy endpoint URL")
          }
        }
        LabeledContent("Status", value: statusText)
        LabeledContent("Active Model", value: activeModelText)
        LabeledContent("Memory State", value: memoryStateText)
        Button("Unload Active Model") { server.unloadActiveModel() }
          .disabled(!canUnloadActiveModel)
        Button("Open Logs…") { server.openLogs() }
          .disabled(server.logURL == nil)
      }

      Section("About") {
        LabeledContent("Dakodeon", value: "Version \(appVersion)")
        Link("Source on GitHub", destination: URL(string: "https://github.com/emin93/dakodeon")!)
        Text("Requires `llama.cpp` and `hf` on the system PATH.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 470, height: 540)
  }

  private var statusText: String {
    switch server.state {
    case .stopped: return "Idle"
    case .starting: return "Starting"
    case .running: return "Running"
    case .failed(let message): return message
    }
  }

  private var activeModelText: String {
    guard let id = server.activeModelID else { return "None" }
    return Catalog.profile(id: id)?.name ?? id
  }

  private var memoryStateText: String {
    guard server.state.isRunning else { return "Offline" }
    switch server.activeModelState {
    case .loaded: return "Loaded"
    case .loading: return "Loading"
    case .sleeping: return "Sleeping"
    case .failed: return server.activeModelDiagnostic ?? "Failed"
    case nil: return "Unloaded"
    }
  }

  private var canUnloadActiveModel: Bool {
    server.activeModelID != nil && server.activeModelState?.isMemoryResident == true
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }
}

private struct ModelRow: View {
  let profile: ModelProfile
  @ObservedObject var server: ServerController
  @ObservedObject var store: ModelStore
  @State private var confirmingDelete = false

  private var status: ModelStatus { store.status(for: profile) }
  private var isActive: Bool { server.activeModelID == profile.id }
  private var activeState: RouterModelState? {
    isActive ? server.activeModelState : nil
  }
  private var routerDiagnostic: String? {
    server.modelDiagnostic(for: profile)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(displayName).font(.system(size: 13, weight: .semibold))
          Text(modelDetail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
          statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        actions
      }

      downloadBar
    }
    .padding(.vertical, 5)
    .confirmationDialog(
      "Delete \(displayName)?",
      isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { server.delete(profile) }
        .disabled(isActive)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(deleteMessage)
    }
  }

  @ViewBuilder private var downloadBar: some View {
    if case .downloading(let progress, let completed, let total) = status {
      VStack(alignment: .leading, spacing: 3) {
        DownloadProgressBar(progress: progress)
        Text(downloadText(progress: progress, completed: completed, total: total))
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var modelDetail: String {
    var parts: [String] = []
    if let size = store.sizeDescription(for: profile) { parts.append(size) }
    if profile.hasVision { parts.append("Vision") }
    if profile.hasDraft { parts.append("MTP draft") }
    return parts.joined(separator: " · ")
  }

  private var displayName: String { profile.name }

  private var deleteMessage: String {
    if let size = store.sizeDescription(for: profile) {
      return "This removes the downloaded files (\(size)) from the cache."
    }
    return "This removes the downloaded files from the cache."
  }

  private func downloadText(progress: Double?, completed: Int64, total: Int64?) -> String {
    let percent = progress.map { "\(Int($0 * 100))% · " } ?? ""
    if let total {
      return "\(percent)\(ByteFormat.string(completed)) / \(ByteFormat.string(total))"
    }
    return "\(percent)\(ByteFormat.string(completed))"
  }

  @ViewBuilder private var statusLine: some View {
    switch status {
    case .downloading:
      EmptyView()
    case .ready:
      if let routerDiagnostic {
        Label(routerDiagnostic, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.orange)
      } else {
        Label("Ready", systemImage: "checkmark.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.green)
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundStyle(.orange)
    case .absent:
      Text("Not downloaded")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder private var actions: some View {
    switch status {
    case .downloading:
      Button(role: .cancel) { server.cancelDownload(profile) } label: {
        Label("Cancel", systemImage: "xmark")
      }
      .controlSize(.small)
    case .ready:
      HStack(spacing: 8) {
        if routerDiagnostic != nil {
          Text("Failed")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.orange.opacity(0.14), in: Capsule())
        } else if isActive {
          Text(activeStateTitle)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(activeStateTint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(activeStateTint.opacity(0.14), in: Capsule())
        }
        if activeState?.isMemoryResident == true {
          Button("Unload") { server.unloadModel(id: profile.id) }
            .controlSize(.small)
        }
        Menu {
          Button("Reveal in Finder") { reveal() }
          Divider()
          Button("Delete…", role: .destructive) { confirmingDelete = true }
            .disabled(isActive)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    case .absent, .failed:
      Button {
        server.download(profile)
      } label: {
        Label(status == .absent ? "Download" : "Retry", systemImage: "arrow.down.circle")
      }
      .controlSize(.small)
    }
  }

  private var activeStateTitle: String {
    switch activeState {
    case .loaded: return "Loaded"
    case .loading: return "Loading"
    case .sleeping: return "Sleeping"
    case .failed: return "Failed"
    case nil: return "Active"
    }
  }

  private var activeStateTint: Color {
    switch activeState {
    case .loaded: return .green
    case .loading: return .orange
    case .sleeping: return .blue
    case .failed: return .orange
    case nil: return .blue
    }
  }

  private func reveal() {
    guard let url = store.localURL(for: profile.weights) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
