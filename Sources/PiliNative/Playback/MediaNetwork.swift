import Foundation
import Network

final class MediaNetwork: @unchecked Sendable {
  static let shared = MediaNetwork()
  let monitor = NWPathMonitor()
  private init() { monitor.start(queue: DispatchQueue(label: "pili.media.network")) }
  var cellular: Bool { monitor.currentPath.usesInterfaceType(.cellular) }
}
