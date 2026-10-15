import ComposableArchitecture
import Dependencies
import SwiftUI

/// Menu section showing model warm/loading state and memory usage, plus a button that forces a
/// full event-tap teardown/recreate and model re-warm without restarting the app.
struct MenuBarReconnectHotkeyButton: View {
  @Shared(.tapHealth) var tapHealth: TapHealthState
  @Shared(.hexSettings) var hexSettings: HexSettings
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.transcription) var transcription

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let now = context.date
      Text(modelText(now))
      Text(memoryText())
      Text(tapText(now))
      Button("Reconnect Hotkey & Rewarm (\(warmAgeText(now)))") {
        reconnect()
      }
    }
  }

  private func modelText(_ now: Date) -> String {
    if let p = tapHealth.loadProgress {
      return "Model: loading \(Int((p * 100).rounded()))%…"
    }
    if let warm = tapHealth.lastWarmAt {
      return "Model: ready · \(shortModelName)"
    }
    return "Model: not warmed yet"
  }

  private func memoryText() -> String {
    let f = Double(tapHealth.physFootprintBytes) / 1_048_576
    let r = Double(tapHealth.residentBytes) / 1_048_576
    if f == 0 { return "Memory: sampling…" }
    return String(format: "Memory: %.0f MB footprint · %.0f MB resident", f, r)
  }

  private func tapText(_ now: Date) -> String {
    var s = tapHealth.tapHealthy ? "Hotkey tap: OK" : "Hotkey tap: unresponsive"
    if let ack = tapHealth.lastTapAckAt {
      s += " · probe ack \(ageText(now.timeIntervalSince(ack))) ago"
    }
    if tapHealth.reconnectCount > 0 {
      s += " · rebuilds \(tapHealth.reconnectCount)"
    }
    return s
  }

  private func warmAgeText(_ now: Date) -> String {
    guard let last = tapHealth.lastWarmAt else { return "warm: never" }
    return "last warmed \(ageText(now.timeIntervalSince(last))) ago"
  }

  private func ageText(_ interval: TimeInterval) -> String {
    let secs = max(0, Int(interval))
    if secs < 60 { return "\(secs)s" }
    if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
    return "\(secs / 3600)h \(secs % 3600 / 60)m"
  }

  private var shortModelName: String {
    let name = hexSettings.selectedModel
    return name.isEmpty ? "none" : name
  }

  private func reconnect() {
    Task {
      _ = await keyEventMonitor.forceReconnect()
      let model = hexSettings.selectedModel
      if !model.isEmpty {
        try? await transcription.prewarm(model)
      }
    }
  }
}
