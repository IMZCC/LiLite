import SwiftUI

struct ArchiveDescription: View {
  let video: Video, wide: Bool, cid: Int64?, duration: Double?, seek: (Double) -> Void
  /// When set, the caller controls expansion: false shows a three-line preview, true the full text.
  var expanded: Bool? = nil
  @AppStorage("sponsor.enabled") private var sponsors = false
  @State private var origin:SponsorSource?
  @State private var website:URL?
  @AppStorage("detail.expandIntro") private var expand = false
  @AppStorage("detail.expandWide") private var expandWide = false
  @State private var override: Bool?
  @State private var route: SharedLink?
  @State private var issue: String?
  @State private var resolve: Task<Void, Never>?
  var body: some View {
    Group {
      if let expanded {
        content.lineLimit(expanded ? nil : 3)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        DisclosureGroup(
      isExpanded: Binding(
        get: { override ?? (expand || (wide && expandWide)) }, set: { value in
          guard (override ?? (expand || (wide && expandWide))) != value else { return }
          TouchFeedback.light()
          override = value
        })
    ) {
      content
    } label: {
      Label("视频简介", systemImage: "text.alignleft")
    }
      }
    }
    .onChange(of:cid){_,_ in origin=nil}
    .piliSheet(item:$origin){SponsorSourceSheet(source:$0)}
    .navigationDestination(item:$website){SitePage(url:$0)}
    .navigationDestination(item: $route) { LinkDestination(item: $0) }
    .onDisappear { resolve?.cancel() }
    .alert("无法打开链接", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
      Button("好") {}
    } message: {
      Text(issue ?? "")
    }
  }
  private var content: some View {
      // The official intro's text: 13 sp in Ga7.
      LinkedDescription(input: .init(video)).font(OfficialIntro.font(13)).lineSpacing(OfficialIntro.d(4))
        .foregroundStyle(OfficialIntro.ga7)
        .textSelection(.enabled)
        .environment(
          \.openURL,
          OpenURLAction { url in
            if url.scheme == "pili-seek", let t = Int(url.lastPathComponent), t >= 0 {
              seek(Double(t))
              return .handled
            }
            if sponsors, let item=SponsorSource(archive:video.bvid,cid:cid,duration:duration,link:url){origin=item;return .handled}
            if let c = SharedResolver.candidate(url.absoluteString) {
              resolve?.cancel()
              resolve = Task { @MainActor in
                do {
                  let r = try await c.resolve()
                  try Task.checkCancellation()
                  route = r
                } catch { if !Task.isCancelled { issue = error.localizedDescription } }
              }
              return .handled
            }
            if ["https","http"].contains(url.scheme?.lowercased() ?? ""),url.user==nil,url.password==nil,url.host != nil {website=url;return .handled}
            return .discarded
          })
  }
}

private struct DescriptionInput: Equatable {
  let bvid: String
  let text: String
  let lines: [Video.IntroLine]

  init(_ video: Video) {
    bvid = video.bvid
    text = video.desc ?? ""
    lines = video.desc_v2 ?? []
  }

  var hasLines: Bool { lines.contains { !($0.raw_text ?? "").isEmpty } }
  var plainText: String {
    guard hasLines else { return text }
    return lines.compactMap { line in
      line.raw_text.map { line.type == 2 && !$0.hasPrefix("@") ? "@" + $0 : $0 }
    }.joined()
  }
}

private struct LinkedDescription: View {
  let input: DescriptionInput
  @State private var rendered: (input: DescriptionInput, text: AttributedString)?
  var body: some View {
    Group {
      if let rendered, rendered.input == input { Text(rendered.text) }
      else { Text(verbatim: input.plainText) }
    }.task(id: input) {
      guard !Task.isCancelled, let text = await DescriptionLinks.shared.text(for: input),
        !Task.isCancelled else { return }
      rendered = (input, text)
    }
  }
}

private actor DescriptionLinks {
  static let shared = DescriptionLinks()
  private var cache: [String: (DescriptionInput, AttributedString)] = [:]
  private static let detector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue)
  private static let pattern = try? NSRegularExpression(
    pattern:
      #"(?<![A-Za-z0-9:])(?:BV[A-Za-z0-9]{10}|av[0-9]+|(?:[0-9]{1,3}:)?[0-9]{1,3}:[0-5][0-9])(?![A-Za-z0-9:])"#
  )
  func text(for input: DescriptionInput) -> AttributedString? {
    guard !Task.isCancelled else { return nil }
    if let entry = cache[input.bvid], entry.0 == input { return entry.1 }
    let result = NSMutableAttributedString(string: "")
    func append(_ text: String, mention: Int64? = nil) {
      let piece = NSMutableAttributedString(string: text)
      let all = NSRange(location: 0, length: (text as NSString).length)
      if let mention, mention > 0 {
        if let url = URL(string: "bilibili://space/" + String(mention)) {
          piece.addAttribute(.link, value: url, range: all)
        }
      } else {
        let external = Self.detector?.matches(in: text, range: all) ?? []
        for r in external {
          if let u = r.url, ["http", "https", "bilibili"].contains(u.scheme?.lowercased() ?? "") {
            piece.addAttribute(.link, value: u, range: r.range)
          }
        }
        for r in Self.pattern?.matches(in: text, range: all) ?? []
        where !external.contains(where: { NSIntersectionRange($0.range, r.range).length > 0 }) {
          let s = (text as NSString).substring(with: r.range)
          let u: URL?
          if s.contains(":") {
            let parts = s.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0 < 60 }) else { continue }
            u = URL(string: "pili-seek://time/" + String(parts.reduce(0) { $0 * 60 + $1 }))
          } else {
            u = URL(string: "https://www.bilibili.com/video/" + s)
          }
          if let u { piece.addAttribute(.link, value: u, range: r.range) }
        }
      }
      result.append(piece)
    }
    if input.hasLines {
      for line in input.lines {
        guard !Task.isCancelled else { return nil }
        guard let text = line.raw_text else { continue }
        if line.type == 2 {
          append(text.hasPrefix("@") ? text : "@" + text, mention: line.bizId)
        } else {
          append(text)
        }
      }
    } else {
      append(input.text)
    }
    guard !Task.isCancelled else { return nil }
    let text = AttributedString(result)
    if cache.count >= 40, cache[input.bvid] == nil, let key = cache.keys.first { cache[key] = nil }
    cache[input.bvid] = (input, text)
    return text
  }
}
