import Foundation

enum PageMotion: Int, CaseIterable {
  case fade, fadeIn, fromRight, fromLeft, fromTop, fromBottom, rightFade, leftFade, zoom, topLevel,
    none, cupertino, cupertinoDialog, revealSize, circle, native, sharedAxis
  var title: String {
    ["向上淡入", "淡入", "从右滑入", "从左滑入", "从上滑入", "从下滑入", "向左滑动并淡入", "向右滑动并淡入",
     "缩放", "层级缩放", "无动画", "iOS 滑动", "iOS 对话页", "展开", "圆形揭示", "系统默认", "共享轴"][rawValue]
  }
  func custom(reduced: Bool, interactivePop: Bool) -> Bool {
    !reduced && !interactivePop && ![Self.native,.cupertino,.cupertinoDialog].contains(self)
  }
  static let key = "layout.pageMotion"
  static var current: Self { (UserDefaults.standard.object(forKey: key) as? Int).flatMap(Self.init(rawValue:)) ?? .native }
}
struct ScrollSpring: Equatable {
  static let key = "layout.scrollSpring"
  static let standard = [1.0, 438.64908449286037, 41.88790204786391]
  let mass: Double, stiffness: Double, damping: Double
  var values: [Double] { [mass, stiffness, damping] }
  var duration: Double { 2 * .pi * sqrt(mass / stiffness) }
  var bounce: Double {
    let ratio = damping / (2 * sqrt(mass * stiffness))
    return ratio < 1 ? 1 - ratio : 1 / ratio - 1
  }
  init?(_ raw: [Double]) {
    guard raw.count == 3, raw.allSatisfy({ $0.isFinite && (0.000001...1_000_000).contains($0) }) else { return nil }
    mass = raw[0]; stiffness = raw[1]; damping = raw[2]
  }
  init?(duration: Double, bounce: Double) {
    guard duration.isFinite && (0.05...5).contains(duration), bounce.isFinite && (-0.99...0.99).contains(bounce) else { return nil }
    let k = pow(2 * .pi / duration, 2), z = bounce > 0 ? 1 - bounce : 1 / (bounce + 1)
    self.init([1, k, 2 * sqrt(k) * z])
  }
  func state(offset x: Double, velocity v: Double, after t: Double) -> (Double, Double) {
    let w = max(2 * Double.pi / 3, min(2 * Double.pi / 0.05, sqrt(stiffness / mass)))
    let z = max(0.02, min(6, damping / (2 * sqrt(mass * stiffness))))
    let decay = w * z
    if abs(z - 1) < 0.00001 {
      let q = v + decay * x, e = exp(-decay * t)
      return (e * (x + q*t), e * (q - decay * (x + q*t)))
    }
    if z < 1 {
      let d = w * sqrt(1 - z*z), q = (v + decay*x) / d
      let s = sin(d*t), c = cos(d*t), e = exp(-decay*t), f = x*c + q*s
      return (e*f, e*(d*(q*c - x*s) - decay*f))
    }
    let r2 = -decay - w*sqrt(z*z - 1), r1 = w*w/r2
    let a = (v - r2*x)/(r1-r2), b = x-a, ea = exp(r1*t), eb = exp(r2*t)
    return (a*ea + b*eb, r1*a*ea + r2*b*eb)
  }
  static func current(_ d: UserDefaults = .standard) -> Self {
    (d.array(forKey: key) as? [Double]).flatMap(Self.init) ?? Self(standard)!
  }
}
