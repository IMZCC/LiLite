import SwiftUI

struct ArchiveShareButtons:View {
  let normal:URL
  let precise:()->URL?
  @Environment(\.openURL) private var open
  @State private var issue:String?
  var body:some View{
    ShareLink(item:normal){Label("分享链接",systemImage:"square.and.arrow.up")}
    Button("复制链接"){UIPasteboard.general.string=normal.absoluteString}
    Button("复制当前进度链接"){UIPasteboard.general.string=(precise() ?? normal).absoluteString}
    Button("用其他应用打开"){open(normal){opened in if !opened{issue="无法打开这个链接"}}}
      .alert("打开链接",isPresented:.init(get:{issue != nil},set:{if !$0{issue=nil}})){Button("好"){}}
      message:{Text(issue ?? "")}
  }
}
