import AppKit
import SwiftUI

@main
struct DakodeonApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var server = ServerController.shared

  var body: some Scene {
    MenuBarExtra {
      MenuView(server: server, store: server.store)
    } label: {
      Image(nsImage: DakodeonImages.statusBarIcon)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(server: server, store: server.store)
    }
  }
}

/// Ensures the `llama-server` process is stopped when the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillTerminate(_ notification: Notification) {
    ServerController.shared.terminateForQuit()
  }
}

enum DakodeonImages {
  /// Monochrome template image for the menu bar.
  static let statusBarIcon: NSImage = {
    let image = appIcon.copy() as! NSImage
    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    return image
  }()

  /// Full-color app mark used inside the panel and Settings.
  static let appIcon: NSImage = {
    if let url = Bundle.main.url(forResource: "DakodeonIcon", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
      return image
    }
    if let image = NSImage(named: "DakodeonIcon") {
      return image
    }
    return fallback()
  }()

  private static func fallback() -> NSImage {
    let image = NSImage(size: NSSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.labelColor.setFill()
    for index in 0..<3 {
      NSBezierPath(
        roundedRect: NSRect(x: 22, y: 18 + index * 12, width: 20, height: 7),
        xRadius: 3, yRadius: 3
      ).fill()
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
  }
}
