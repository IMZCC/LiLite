import Foundation

struct LiveEmoji: Decodable, Identifiable {
  let emoticon_unique: String?, emoji: String?, url: String?, width:Int?, height:Int?, perm:Int?, unlock_show_text:String?
  var id:String {emoticon_unique ?? emoji ?? ""}
  var available:Bool {perm != 0}
}
struct LiveEmoteChoices: Decodable {
  struct Group:Decodable {
    let pkg_type:Int?,current_cover:String?,pkg_name:String?,emoticons:[LiveEmoji]?
    var insertsText:Bool {pkg_type == 3}
    var rows:[LiveEmoji] {
      var seen=Set<String>()
      return (emoticons ?? []).filter { e in
        let key = insertsText ? e.emoji : e.emoticon_unique
        return key.map{!$0.isEmpty && seen.insert($0).inserted} ?? false
      }
    }
  }
  let data:[Group]?
  var groups:[Group]{ (data ?? []).filter{!$0.rows.isEmpty} }
  static func insert(_ token:String,in text:String,selection:NSRange?) -> (String,NSRange) {
    let s=text as NSString
    let end=NSRange(location:s.length,length:0)
    let span=selection.flatMap{range in
      range.location>=0 && range.location<=s.length && range.length>=0 && range.length<=s.length-range.location && Range(range,in:text) != nil ? range:nil
    } ?? end
    return (s.replacingCharacters(in:span,with:token),NSRange(location:span.location+(token as NSString).length,length:0))
  }
}
