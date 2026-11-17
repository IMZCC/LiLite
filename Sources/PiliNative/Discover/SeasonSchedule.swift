import Foundation

enum SeasonSchedule {
  struct Day: Decodable, Identifiable {
    let date: String, date_ts: Int, is_today: Int?, episodes: [Entry]?
    var id: Int { date_ts }
  }
  struct Entry: Decodable, Identifiable {
    let season_id: Int64, title: String, cover: String, pub_index: String?, pub_time: String?,
      episode_id: Int64?
    let published: Int?, delay: Int?, delay_reason: String?
    var follow: Int? = nil
    var playableEpisodeID:Int64?{guard published != 0,delay != 1,let n=episode_id,n>0 else{return nil};return n}
    var id: String { "\(season_id):\(episode_id ?? 0):\(pub_index ?? "")" }
  }
  static func merge(_ inputs: [[Day]]) -> [Day] {
    var days = [Int: Day]()
    for list in inputs {
      for day in list {
        let old = days[day.id]
        var seen = Set<String>()
        let all = ((old?.episodes ?? []) + (day.episodes ?? [])).filter {
          seen.insert($0.id).inserted
        }
        days[day.id] = .init(
          date: day.date, date_ts: day.id, is_today: old?.is_today == 1 ? 1 : day.is_today,
          episodes: all)
      }
    }
    return days.values.sorted { $0.id < $1.id }
  }
}
