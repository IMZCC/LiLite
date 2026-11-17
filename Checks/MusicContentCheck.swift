import Foundation

@main struct MusicContentCheck {
  static func main() throws {
    let decoder = JSONDecoder()
    let bgm = try decoder.decode(ArchiveTag.self,from:Data(#"{"tag_type":"bgm","tag_name":"发现一首歌","music_id":"MA651"}"#.utf8))
    precondition(bgm.route == .music("MA651") && bgm.label == "♫ 一首歌")
    let m = try decoder.decode(MusicRecord.self,from:Data(#"{"mv_aid":81,"mv_cid":71,"achievement":["A","B"],"music_rank":"B","recreation_rank":"C","hot_song_heat":{"song_heat":[{"date":2,"heat":10},{"date":1,"heat":8},{"date":2,"heat":13},{"date":0,"heat":100}]},"wish_listen":true,"music_comment":{"oid":4}}"#.utf8))
    precondition(m.mv == .archivePart(.archive(81,nil),71) && m.awards == ["A","B","C"])
    precondition(m.trend.map(\.heat) == [8,10] && m.wishFields(id:"MA651") == ["state":"2","music_id":"MA651"])
    let list = try decoder.decode(MusicClips.self,from:Data(#"{"list":[{"bvid":"BV1xx411c7mD","cid":1},{"bvid":"BV1xx411c7mD","cid":2},{"bvid":"BV1xx411c7mD","cid":2},{"bvid":"BV1xx411c7mD"},{"bvid":"av1","cid":1}]}"#.utf8))
    precondition(list.videos.map(\.route) == [.archivePart(.video("BV1xx411c7mD",nil),1),.archivePart(.video("BV1xx411c7mD",nil),2),.video("BV1xx411c7mD",nil)])
    if CommandLine.arguments.count == 2 {
      let raw = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
      let sample = try JSONSerialization.jsonObject(with:raw) as! [Any]
      func data(_ i:Int)throws->Data { try JSONSerialization.data(withJSONObject:sample[i]) }
      let tags = try decoder.decode([ArchiveTag].self,from:data(0))
      let song = try decoder.decode(MusicRecord.self,from:data(1))
      let uses = try decoder.decode(MusicClips.self,from:data(2))
      precondition(tags.contains { if case .music = $0.route {return true};return false })
      precondition(song.music_title?.isEmpty == false && song.music_comment?.oid != nil && !uses.videos.isEmpty)
      print("Public music readback: \(tags.count) tags, \(song.artists_list?.count ?? 0) artists, \(song.trend.count) trend points, \(uses.videos.count) playable recommendations, MV \(song.mv != nil)")
    }
    print("Archive music tags, song charts, wishes, shared IDs and part-specific music recommendations passed")
  }
}
