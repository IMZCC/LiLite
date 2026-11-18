import Foundation

@main enum PhoneLayoutCheck {
  static func main() {
    let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
    let outer = CGSize(width: 466, height: 678), inner = CGSize(width: 626, height: 890)
    let book = CGRect(x: 305, y: 0, width: 16, height: 890)
    let tabletop = CGRect(x: 0, y: 305, width: 890, height: 16)
    let safe = CGRect(x: 0, y: 62, width: phone.width, height: 778)
    precondition(FeedHeaderInsets.window(bounds: phone, safe: safe, rightToLeft: false) == .init(top: 62))
    precondition(FeedHeaderInsets.window(bounds: safe, safe: safe, rightToLeft: false) == .init())
    let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
    let sideSafe = CGRect(x: 54, y: 0, width: 800, height: 390)
    precondition(FeedHeaderInsets.window(bounds: landscape, safe: sideSafe, rightToLeft: false)
      == .init(leading: 54, trailing: 20))
    precondition(FeedHeaderInsets.window(bounds: landscape, safe: sideSafe, rightToLeft: true)
      == .init(leading: 20, trailing: 54))
    for size in [phone.size, landscape.size, outer, CGSize(width: 390, height: 890)] {
      precondition(!PlayerPageLayout.isLargeWindow(size))
      precondition(PlayerPageLayout.resolve(width: size.width, height: size.height, horizontal: false) == .stacked)
      precondition(FeedHeaderInsets.avoiding(width: size.width, height: 100, regions: []) == .init())
    }
    precondition(PlayerPageLayout.isLargeWindow(inner))
    precondition(PlayerPageLayout.resolve(width: 890, height: 626, horizontal: true) == .side)
    precondition(PlayerPageLayout.partition(width: 626, height: 890, fold: nil) == nil)
    let side = PlayerPageLayout.partition(width: 626, height: 890, fold: book)
    precondition(side?.mode == .side && side?.edge == book.minX && side?.gap == book.width)
    let upper = PlayerPageLayout.partition(width: 890, height: 626, fold: tabletop)
    precondition(upper?.mode == .tabletop && upper?.edge == tabletop.minY && upper?.gap == tabletop.height)
    let camera = CGRect(x: 574, y: 0, width: 52, height: 52)
    precondition(FeedHeaderInsets.avoiding(width: 626, height: 100, regions: [camera]) == .init(trailing: 52))
    precondition(FeedHeaderInsets.avoiding(width: 626, height: 100, regions: [book]) == .init(leading: 321))
    precondition(FeedHeaderInsets.avoiding(width: 626, height: 100, regions: [camera, book]) == .init(trailing: 321))
    precondition(FeedHeaderInsets.avoiding(width: 890, height: 100, regions: [tabletop]) == .init())
    precondition(FeedHeaderInsets.avoiding(width: 890, height: 100,
      regions: [tabletop.offsetBy(dx: 0, dy: -250)]) == .init(top: 71))
    print("Phone and Duo layout checks passed: portrait, landscape, safe-area reuse, RTL, outer and inner windows, split view, book, tabletop and camera")
  }
}
