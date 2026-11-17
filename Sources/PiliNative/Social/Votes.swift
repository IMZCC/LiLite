import SwiftUI

struct VoteRef: Identifiable { let id: Int64, title: String }

struct VoteView: View {
  let id: Int64, dynamic: String
  struct Option: Decodable, Identifiable {
    let opt_idx: Int, opt_desc: String?, cnt: Int?, img_url: String?
    var id: Int { opt_idx }
  }
  struct Vote: Decodable {
    let title: String?, desc: String?, choice_cnt: Int?, end_time: Int64?, join_num: Int?, options: [Option]?, vote_publisher: Int64?, type: Int?
    private enum CodingKeys: String, CodingKey { case title, desc, choice_cnt, end_time, join_num, options, vote_publisher, type }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      func number(_ key: CodingKeys) -> Int64? {
        (try? c.decode(Int64.self, forKey: key)) ?? (try? c.decode(String.self, forKey: key)).flatMap(Int64.init)
      }
      title = try c.decodeIfPresent(String.self, forKey: .title)
      desc = try c.decodeIfPresent(String.self, forKey: .desc)
      options = try c.decodeIfPresent([Option].self, forKey: .options)
      choice_cnt = number(.choice_cnt).flatMap(Int.init(exactly:))
      end_time = number(.end_time)
      join_num = number(.join_num).flatMap(Int.init(exactly:))
      vote_publisher = number(.vote_publisher)
      type = number(.type).flatMap(Int.init(exactly:))
    }
  }
  struct Envelope: Decodable { let vote_info: Vote, my_votes: [Int]? }
  @EnvironmentObject private var accounts: AccountContext
  @State private var info: Vote?
  @State private var chosen: Set<Int> = []
  @State private var voted = false
  @State private var anonymous = false
  @State private var percentages = false
  @State private var busy = false
  @State private var issue: String?
  @State private var reload = 0
  private struct LoadKey: Hashable { let vote: Int64, owner: String?, reload: Int }
  var body: some View {
    TimelineView(.explicit([Date.distantPast] + (info?.end_time.map { [Date(timeIntervalSince1970: Double($0))] } ?? []).filter { $0 > .now })) { now in
      Form {
        if let v = info {
          let ended = Int64(now.date.timeIntervalSince1970) >= (v.end_time ?? .max)
          let options = v.options ?? []
          Section {
            Text(v.title ?? "投票").piliFont(.headline)
            if let s = v.desc, !s.isEmpty { Text(s) }
            if let end = v.end_time { Text("截止：\(Date(timeIntervalSince1970: Double(end)).formatted())").piliFont(.caption) }
            Text("\(v.join_num ?? 0) 人参与").foregroundStyle(.secondary)
            if ended { Text("已结束") } else if voted { Text("已投票") }
          }
          Section {
            ForEach(options) { o in option(o, vote: v, locked: voted || ended) }
          }
          if !voted && !ended {
            Toggle("显示比例", isOn: $percentages)
            Toggle("匿名投票", isOn: $anonymous)
            Button("提交投票") { Task { await send() } }
              .disabled(busy || chosen.isEmpty || accounts.state.active == nil)
          }
          if let owner = accounts.state.active {
            FolloweeBallots(vote: id, owner: owner, options: options)
              .id("\(id):\(owner)")
          }
        } else if issue == nil { ProgressView() }
        if let issue {
          Text(issue); Button("重试") { reload += 1 }
        }
      }
    }.navigationTitle("投票")
      .task(id: LoadKey(vote: id, owner: accounts.state.active, reload: reload)) {
        let uid = accounts.state.active
        info = nil; issue = nil; chosen = []; voted = false; percentages = false; anonymous = false
        do {
          let r = try await BiliAPI.shared.read("/x/vote/vote_info", ["vote_id": String(id)], expectedAccount: uid ?? "", as: Envelope.self)
          try Task.checkCancellation()
          guard accounts.state.active == uid else { return }
          info = r.vote_info
          chosen = Set(r.my_votes ?? [])
          voted = !chosen.isEmpty
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      }
  }
  private func option(_ o: Option, vote: Vote, locked: Bool) -> some View {
    let options = vote.options ?? []
    let pictures = options.compactMap { $0.img_url.flatMap(GalleryPicture.source).map { GalleryPicture($0) } }
    return HStack {
      if let url = o.img_url.flatMap(GalleryPicture.source), let index = pictures.firstIndex(where: { $0.url == url }) {
        GalleryLink(pictures, index: index) {
          SiteThumbnail(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 44, height: 44)
        }.accessibilityLabel("预览选项图片").buttonStyle(.borderless)
      }
      Button {
        let limit = max(1, vote.choice_cnt ?? options.count)
        if chosen.contains(o.id) { chosen.remove(o.id) }
        else if limit == 1 { chosen = [o.id] }
        else if chosen.count < limit { chosen.insert(o.id) }
      } label: {
        HStack {
          Image(systemName: chosen.contains(o.id) ? "checkmark.circle.fill" : "circle")
          Text(o.opt_desc ?? "")
          Spacer()
          if locked || percentages {
            let total = options.reduce(0.0) { $0 + Double(max(0, $1.cnt ?? 0)) }
            let count = max(0, o.cnt ?? 0)
            Text("\(count) 票 · \((total > 0 ? Double(count) / total : 0).formatted(.percent.precision(.fractionLength(0...1))))")
              .piliFont(.caption)
          }
        }.contentShape(Rectangle())
      }.disabled(locked || busy).buttonStyle(.plain)
    }
  }
  private func send() async {
    guard !busy, let owner = accounts.state.active, let v = info, !voted, !chosen.isEmpty,
      (v.end_time ?? .max) > Int64(Date().timeIntervalSince1970) else { return }
    busy = true
    defer { busy = false }
    do {
      guard let user = try await AccountJar.shared.current(), user.id == owner, let csrf = user.csrf,
        let mid = Int64(owner) else { throw ServiceError("账号已切换") }
      _ = try await BiliAPI.shared.dynPost("/x/vote/do_vote", [
        "vote_id": id, "votes": chosen.sorted(), "voter_uid": mid, "status": anonymous ? 1 : 0,
        "op_bit": 0, "dynamic_id": Int64(dynamic) ?? 0, "csrf": csrf, "csrf_token": csrf,
      ], expectedAccount: owner)
      guard accounts.state.active == owner else { return }
      voted = true; reload += 1
    } catch { if accounts.state.active == owner { issue = error.localizedDescription } }
  }
}

private struct FolloweeBallots: View {
  let vote: Int64, owner: String, options: [VoteView.Option]
  struct Ballot: Decodable, Identifiable {
    let uid: Int64, name: String?, face: String?, votes: [Int]?, ctime: Int64?
    var id: Int64 { uid }
  }
  struct Result: Decodable { let votes: [Ballot]? }
  @State private var people = [Ballot]()
  @State private var loading = true
  @State private var issue: String?
  @State private var retry = 0
  var body: some View {
    NavigationLink(people.isEmpty ? "关注的人的投票" : "关注的人的投票（\(people.count)）") {
          List {
            if loading { ProgressView() }
            else if let issue { Text(issue); Button("重试") { retry += 1 } }
            else if people.isEmpty { Text("暂无公开投票").foregroundStyle(.secondary) }
            ForEach(people) { person in
            NavigationLink {
              CreatorSpace(mid: person.uid, name: person.name ?? "用户空间")
            } label: {
              HStack {
                if let url = person.face.flatMap(httpsURL) {
                  SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    .frame(width: 36, height: 36).clipShape(Circle())
                }
                VStack(alignment: .leading) {
                  Text(person.name ?? "用户")
                  Text((person.votes ?? []).compactMap { id in options.first(where: { $0.id == id })?.opt_desc }.joined(separator: "、")).foregroundStyle(.secondary)
                }
              }
            }
            }
          }.navigationTitle("关注的人的投票")
            .task(id: retry) {
              loading = true; issue = nil
              defer { if !Task.isCancelled { loading = false } }
              do {
                let page = try await BiliAPI.shared.read("/vote_svr/v1/vote_svr/followee_votes", ["vote_id": String(vote)], host: "api.vc.bilibili.com", expectedAccount: owner, as: Result.self)
                try Task.checkCancellation()
                people = page.votes ?? []
              } catch { if !Task.isCancelled { issue = error.localizedDescription } }
            }
    }
  }
}
