import ComposableArchitecture
import Foundation

/// Live liveness info surfaced to the menu bar: when the model was last warmed, when the event
/// tap last acknowledged a health probe, and rebuild history.
struct TapHealthState: Equatable {
  var lastWarmAt: Date?
  var lastTapAckAt: Date?
  var lastReconnectAt: Date?
  var reconnectCount: Int = 0
  /// 0..1 while the model is (re)loading; nil when idle.
  var loadProgress: Double?
  var physFootprintBytes: UInt64 = 0
  var residentBytes: UInt64 = 0
  var tapHealthy: Bool = false
}

extension SharedReaderKey where Self == InMemoryKey<TapHealthState>.Default {
  static var tapHealth: Self {
    Self[
      .inMemory("tapHealth"),
      default: .init()
    ]
  }
}
