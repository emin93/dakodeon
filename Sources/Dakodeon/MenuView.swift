import AppKit
import SwiftUI

/// The slim menu bar panel.
struct MenuView: View {
  @ObservedObject var server: ServerController
  @ObservedObject var store: ModelStore
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      header
      modelSection
      actionSection
      if case .failed(let message) = server.state {
        errorRow(message)
      }
      Divider()
      footer
    }
    .padding(15)
    .frame(width: 286)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 9) {
      Image(nsImage: DakodeonImages.appIcon)
        .resizable()
        .interpolation(.high)
        .frame(width: 21, height: 21)
      Text("Dakodeon")
        .font(.system(size: 14, weight: .semibold))
      Spacer()
      StatusPill(state: server.state)
    }
  }

  // MARK: Model

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("MODEL")
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(.tertiary)

      Menu {
        ForEach(Catalog.profiles) { profile in
          Button(profile.name) { server.selectProfile(profile.id) }
        }
      } label: {
        HStack(spacing: 8) {
          Text(server.selectedProfile?.name ?? "Select a model")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        }
      }
      .menuStyle(.button)
      .buttonStyle(SelectButtonStyle())
      .menuIndicator(.hidden)
    }
  }

  // MARK: Action

  @ViewBuilder private var actionSection: some View {
    if case .downloading(let progress, let completed, let total) = server.selectedStatus {
      downloadView(progress: progress, completed: completed, total: total)
    } else {
      primaryButton
    }
  }

  private func downloadView(progress: Double, completed: Int64, total: Int64) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ProgressView(value: progress)
        .progressViewStyle(.linear)
        .tint(.blue)
      HStack {
        Text("Downloading \(Int(progress * 100))%")
        Spacer()
        Text("\(ByteFormat.string(completed)) / \(ByteFormat.string(total))")
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      Button {
        if let profile = server.selectedProfile { server.cancelDownload(profile) }
      } label: {
        Text("Cancel").frame(maxWidth: .infinity)
      }
      .controlSize(.regular)
    }
  }

  private var primaryButton: some View {
    Button {
      server.toggle()
    } label: {
      HStack(spacing: 6) {
        if server.state.isStarting {
          ProgressView().controlSize(.small).scaleEffect(0.62).frame(width: 11, height: 11).tint(.white)
        } else {
          Image(systemName: server.state.isActive ? "stop.fill" : "play.fill")
            .font(.system(size: 11, weight: .bold))
        }
        Text(actionTitle).font(.system(size: 13, weight: .semibold))
      }
    }
    .buttonStyle(RunButtonStyle(fill: server.state.isRunning ? Theme.stop : Theme.accent))
    .disabled(server.selectedProfile == nil)
  }

  private var actionTitle: String {
    switch server.state {
    case .running: return "Stop Server"
    case .starting: return "Starting…"
    case .stopped, .failed: return "Start Server"
    }
  }

  // MARK: Error

  private func errorRow(_ message: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 10))
        .foregroundStyle(.orange)
      Text(message)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 0) {
      FooterButton(title: "Settings", systemImage: "gearshape") {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }
      Spacer()
      FooterButton(title: "Logs", systemImage: "doc.text") {
        server.openLogs()
      }
      .disabled(server.logURL == nil)
      Spacer()
      FooterButton(title: "Quit", systemImage: "power") {
        NSApp.terminate(nil)
      }
    }
  }
}

enum Theme {
  /// Solid system blue (#0A84FF) — used opaque so it reads well over the panel material.
  static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 1)
  /// Stop red (#FF453A).
  static let stop = Color(red: 1, green: 69 / 255, blue: 58 / 255)
}

/// A solid, high-contrast run/stop button that doesn't wash out over the panel's material.
private struct RunButtonStyle: ButtonStyle {
  let fill: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .frame(height: 32)
      .background(
        fill.opacity(configuration.isPressed ? 0.82 : 1),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .contentShape(RoundedRectangle(cornerRadius: 9))
  }
}

/// A full-width bordered field used (via `.menuStyle(.button)`) for the model selector.
private struct SelectButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 11)
      .frame(height: 33)
      .background(.quaternary.opacity(configuration.isPressed ? 0.8 : 0.5),
                  in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct StatusPill: View {
  let state: ServerState

  var body: some View {
    HStack(spacing: 5) {
      indicator
      Text(title)
        .font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(tint.opacity(0.13), in: Capsule())
  }

  @ViewBuilder private var indicator: some View {
    switch state {
    case .starting:
      ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 8, height: 8)
    case .running:
      Circle().fill(tint).frame(width: 6, height: 6)
    case .failed:
      Image(systemName: "exclamationmark").font(.system(size: 8, weight: .bold))
    case .stopped:
      Circle().strokeBorder(tint, lineWidth: 1.3).frame(width: 6, height: 6)
    }
  }

  private var title: String {
    switch state {
    case .stopped: return "Idle"
    case .starting: return "Starting"
    case .running: return "Running"
    case .failed: return "Error"
    }
  }

  private var tint: Color {
    switch state {
    case .stopped: return .secondary
    case .starting: return .orange
    case .running: return .green
    case .failed: return .orange
    }
  }
}

private struct FooterButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: systemImage).font(.system(size: 11))
        Text(title).font(.system(size: 11.5, weight: .medium))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
  }
}
