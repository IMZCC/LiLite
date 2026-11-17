import AVFoundation

/// AVFoundation's own HTTP loaders send authentication challenges through this public delegate.
final class MediaCertificatePolicy: NSObject, AVAssetResourceLoaderDelegate {
  private static let shared = MediaCertificatePolicy()
  private static let queue = DispatchQueue(label: "PiliNative.MediaCertificates")
  static func apply(to asset: AVURLAsset) {
    asset.resourceLoader.setDelegate(shared, queue: queue)
  }
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForResponseTo challenge: URLAuthenticationChallenge
  ) -> Bool {
    guard let credential = ServerCertificatePolicy.credential(for: challenge), let sender = challenge.sender
    else { return false }
    sender.use(credential, for: challenge)
    return true
  }
}
