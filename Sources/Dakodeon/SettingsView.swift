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
  private var isActive: Bool { server.selectedProfileID == profile.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(profile.name).font(.system(size: 13, weight: .semibold))
            if isActive {
              Text("Active")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.14), in: Capsule())
            }
          }
          Text("\(profile.detail) · \(ByteFormat.string(profile.bytes))")
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
      "Delete \(profile.name)?",
      isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { store.delete(profile) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the downloaded files (\(ByteFormat.string(profile.bytes))) from the cache.")
    }
  }

  @ViewBuilder private var downloadBar: some View {
    if case .downloading(let progress, let completed, let total) = status {
      VStack(alignment: .leading, spacing: 3) {
        ProgressView(value: progress).progressViewStyle(.linear).tint(.blue)
        Text("\(Int(progress * 100))% · \(ByteFormat.string(completed)) / \(ByteFormat.string(total))")
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var statusLine: some View {
    switch status {
    case .downloading:
      EmptyView()
    case .ready:
      Label("Ready", systemImage: "checkmark.circle.fill")
        .font(.system(size: 11))
        .foregroundStyle(.green)
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
        if !isActive {
          Button("Use") { server.selectProfile(profile.id) }
            .controlSize(.small)
        }
        Menu {
          Button("Reveal in Finder") { reveal() }
          Divider()
          Button("Delete…", role: .destructive) { confirmingDelete = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    case .absent, .failed:
      Button {
        store.download(profile)
      } label: {
        Label(status == .absent ? "Download" : "Retry", systemImage: "arrow.down.circle")
      }
      .controlSize(.small)
    }
  }

  private func reveal() {
    guard let url = store.localURL(for: profile.weights) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
