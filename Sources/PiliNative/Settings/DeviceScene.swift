import UIKit

@MainActor final class DeviceSceneDelegate: NSObject, UIWindowSceneDelegate {
  @available(iOS 26.0, *)
  func preferredWindowingControlStyle(for windowScene: UIWindowScene) -> UIWindowScene.WindowingControlStyle {
    .minimal
  }
}

extension DownloadLifecycle {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    application.applicationSupportsShakeToEdit = false
    return true
  }
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: nil, sessionRole: session.role)
    if session.role == .windowApplication { config.delegateClass = DeviceSceneDelegate.self }
    return config
  }
}
