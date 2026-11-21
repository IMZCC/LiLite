import Foundation
import os

/// Who a media request presents itself as. Bilibili's CDN checks a signed address against the
/// client it was issued to: addresses from the web player (`platform=pc` / `html5`) want a browser
/// with the page as Referer, while those the app's own services hand out (the listener's audio,
/// `platform=android_hd`, `iphone`…) are refused with HTTP 403 unless they come from the app's
/// player. A browser identity on an app address is what made 听视频 fail with 这项操作无法完成.
enum MediaClientIdentity: Sendable, Equatable {
  case browser, appPlayer

  static let appAgent = "Bilibili Freedoooooom/MarkII"
  static let browserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

  private static let appPlatforms: Set<String> = [
    "android", "android_hd", "android_i", "android_b", "android_tv", "android_tv_yst",
    "iphone", "iphone_i", "iphone_b", "ipad", "ios",
  ]

  /// The identity the address was signed for, read from its query.
  static func expected(for url: URL) -> Self {
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
      return .browser
    }
    if let platform = items.first(where: { $0.name == "platform" })?.value?.lowercased(),
      appPlatforms.contains(platform)
    {
      return .appPlayer
    }
    return items.contains { $0.name == "mobi_app" } ? .appPlayer : .browser
  }

  var other: Self { self == .browser ? .appPlayer : .browser }

  func apply(to request: inout URLRequest, reference: URL) {
    switch self {
    case .browser:
      request.setValue(reference.absoluteString, forHTTPHeaderField: "Referer")
      request.setValue(Self.browserAgent, forHTTPHeaderField: "User-Agent")
    case .appPlayer:
      request.setValue(nil, forHTTPHeaderField: "Referer")
      request.setValue(Self.appAgent, forHTTPHeaderField: "User-Agent")
    }
  }

  /// Whether a failure means the CDN refused this identity (and the other one is worth a try).
  static func refused(_ error: Error) -> Bool {
    (error as? RangeHTTPStatus).map { $0.code == 403 } ?? false
  }
}

/// The identity a loader settled on for one address: starts from what the address says and
/// switches once if the CDN refuses it.
final class MediaClientChoice: Sendable {
  private let state: OSAllocatedUnfairLock<(identity: MediaClientIdentity, flipped: Bool)>
  init(_ url: URL) { state = .init(initialState: (MediaClientIdentity.expected(for: url), false)) }
  var current: MediaClientIdentity { state.withLock { $0.identity } }
  /// After a refusal by `used`: true when the other identity should be tried.
  func refused(_ used: MediaClientIdentity) -> Bool {
    state.withLock { s in
      if s.identity != used { return true }  // another request already switched
      guard !s.flipped else { return false }
      s.identity = used.other
      s.flipped = true
      return true
    }
  }
}
