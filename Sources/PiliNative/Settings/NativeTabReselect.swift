import SwiftUI
import UIKit

/// Keep the system tab bar and its delegate, adding the existing reselect-to-top action.
struct NativeTabReselect: UIViewControllerRepresentable {
  let tab: MainTab
  let reselected: (MainTab) -> Void
  func makeUIViewController(context: Context) -> Probe { Probe(tab: tab, reselected: reselected) }
  func updateUIViewController(_ controller: Probe, context: Context) {
    controller.mainTab = tab; controller.reselected = reselected; controller.attach()
  }
  static func dismantleUIViewController(_ controller: Probe, coordinator: ()) { controller.detach() }
  final class Probe: UIViewController {
    var mainTab: MainTab
    var reselected: (MainTab) -> Void
    private let token = UUID()
    private weak var attached: UITabBarController?
    init(tab: MainTab, reselected: @escaping (MainTab) -> Void) {
      self.mainTab = tab; self.reselected = reselected
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
      view = UIView(); view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
    }
    override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); attach() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
    func attach() {
      guard isViewLoaded, view.window != nil, let controller = tabBarController else { return }
      var item: UIViewController = self
      while let parent = item.parent, parent !== controller { item = parent }
      guard item.parent === controller else { return }
      if attached !== controller { detach(); attached = controller }
      TabDelegate.install(controller, token: token, item: item, tab: mainTab, reselected: reselected)
    }
    func detach() {
      if let attached { TabDelegate.remove(attached, token: token) }
      attached = nil
    }
  }
}

private final class TabDelegate: NSObject, UITabBarControllerDelegate {
  private static var key: UInt8 = 0
  private weak var original: UITabBarControllerDelegate?
  private struct Registration {
    weak var item: UIViewController?
    let tab: MainTab, action: (MainTab) -> Void
  }
  private var values: [UUID: Registration] = [:]
  private var pending = Set<MainTab>()
  static func install(_ controller: UITabBarController, token: UUID, item: UIViewController, tab: MainTab,
                      reselected: @escaping (MainTab) -> Void) {
    let proxy: TabDelegate
    if let existing = objc_getAssociatedObject(controller, &key) as? TabDelegate { proxy = existing }
    else {
      proxy = TabDelegate()
      objc_setAssociatedObject(controller, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    if controller.delegate !== proxy {
      proxy.original = controller.delegate
      controller.delegate = proxy
    }
    proxy.values = proxy.values.filter { $0.value.item != nil }
    proxy.values[token] = Registration(item: item, tab: tab, action: reselected)
  }
  static func remove(_ controller: UITabBarController, token: UUID) {
    guard let proxy = objc_getAssociatedObject(controller, &key) as? TabDelegate else { return }
    proxy.values[token] = nil
    proxy.values = proxy.values.filter { $0.value.item != nil }
    if proxy.values.isEmpty {
      if controller.delegate === proxy { controller.delegate = proxy.original }
      objc_setAssociatedObject(controller, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
  override func responds(to selector: Selector!) -> Bool {
    if #available(iOS 18.0, *),
      selector == #selector(UITabBarControllerDelegate.tabBarController(_:shouldSelectTab:)) {
      // Do not make UIKit prefer the new callback when the original delegate only handles the old one.
      return original?.responds(to: selector) == true
    }
    return super.responds(to: selector) || original?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
  func tabBarController(_ controller: UITabBarController, shouldSelect item: UIViewController) -> Bool {
    let repeated = controller.selectedViewController === item
    let allowed: Bool
    if let decision = original?.tabBarController?(controller, shouldSelect: item) { allowed = decision }
    else if #available(iOS 18.0, *), let tab = controller.tabs.first(where: { $0.viewController === item }) {
      allowed = original?.tabBarController?(controller, shouldSelectTab: tab) ?? true
    } else { allowed = true }
    if allowed && repeated { enqueue(item, in: controller) }
    return allowed
  }
  @available(iOS 18.0, *)
  func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    let repeated = controller.selectedTab === tab
    let item = controller.selectedViewController
    let allowed: Bool
    if let decision = original?.tabBarController?(controller, shouldSelectTab: tab) { allowed = decision }
    else if let target = tab.viewController {
      allowed = original?.tabBarController?(controller, shouldSelect: target) ?? true
    } else {
      allowed = original?.responds(to: #selector(UITabBarControllerDelegate.tabBarController(_:shouldSelect:))) != true
    }
    if allowed && repeated, let item { enqueue(item, in: controller) }
    return allowed
  }
  private func enqueue(_ item: UIViewController, in controller: UITabBarController) {
    guard let entry = values.first(where: { $0.value.item === item }),
      pending.insert(entry.value.tab).inserted else { return }
    let token = entry.key, tab = entry.value.tab
    // UIKit may send the modern UITab and legacy controller callbacks for the same tap.
    DispatchQueue.main.async { [weak self, weak controller, weak item] in
      guard let self, self.pending.remove(tab) != nil else { return }
      guard let controller, let item, controller.selectedViewController === item,
        let current = self.values[token], current.item === item else { return }
      current.action(tab)
    }
  }
}
