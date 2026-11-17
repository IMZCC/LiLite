import Foundation

@main enum ArticleBodyCheck {
  static func main() {
    // Identical visible labels may point to different people. Offsets include surrogate pairs.
    let nodeMaps: [[String: Any]] = [
      ["type": "RICH_TEXT_NODE_TYPE_TEXT", "orig_text": "🎬"],
      ["type": "RICH_TEXT_NODE_TYPE_AT", "text": "@甲", "rid": "7"],
      ["type": "RICH_TEXT_NODE_TYPE_AT", "text": "@甲", "rid": "8"],
      [
        "type": "RICH_TEXT_NODE_TYPE_EMOJI", "orig_text": "[笑]",
        "emoji": ["icon_url": "//i0.hdslb.com/e.png", "size": 2],
      ],
      ["type": "RICH_TEXT_NODE_TYPE_TOPIC", "orig_text": "#电影#"],
      ["type": "RICH_TEXT_NODE_TYPE_VOTE", "text": "投票", "rid": "12"],
      [
        "type": "RICH_TEXT_NODE_TYPE_VIEW_PICTURE", "text": "看图",
        "pics": [["src": "//i0.hdslb.com/p.jpg"]],
      ],
      ["type": "RICH_TEXT_NODE_TYPE_UNKNOWN", "text": "保留文字", "jump_url": "javascript:noop"],
    ]
    let parsed = RichNode.body(["rich_text_nodes": nodeMaps])
    let doc = InlineDocument(nodes: parsed)
    precondition(doc.text == "🎬@甲@甲[笑]#电影#投票看图保留文字")
    precondition(
      doc.links.prefix(2).map(\.range) == [
        NSRange(location: 2, length: 2), NSRange(location: 4, length: 2),
      ])
    precondition(
      doc.target(doc.links[0].url) == .route(.creator(7))
        && doc.target(doc.links[1].url) == .route(.creator(8)))
    precondition(
      doc.images.first?.range == NSRange(location: 6, length: 3)
        && doc.images.first?.image.size == 2)
    precondition(
      parsed[4].target == .search("电影") && parsed[5].target == .vote(12)
        && parsed.last?.target == nil)
    if case .gallery(let images) = parsed[6].target {
      precondition(images.count == 1)
    } else {
      preconditionFailure()
    }
    let paragraph = ArticleBody.spans([
      "nodes": [["word": ["words": "A", "style": ["bold": true]]], ["rich": nodeMaps[3]]]
    ])
    let doc2 = InlineDocument(nodes: paragraph.map { $0.inline() })
    precondition(doc2.text == "A[笑]" && doc2.images.count == 1 && doc2.styles.first?.bold == true)
    // The importer must preserve order and formatting across inline nodes, images and quoted paragraphs.
    let sample =
      #"<p>A &amp; <b>strong</b> <a href="https://example.org/r">link</a></p><img src="//img.example.org/f.jpg" alt="illustration"><blockquote><p>quote</p></blockquote><script>alert('hidden')</script><pre>&lt;code&gt;</pre>"#
    let rows = ArticleBody.html(sample)
    precondition(rows.count == 4)
    if case .paragraph(let spans) = rows[0] {
      precondition(
        spans.map(\.value).joined() == "A & strong link"
          && spans.contains(where: { $0.bold && $0.value == "strong" })
          && spans.last?.url?.host == "example.org")
    } else {
      fatalError("missing paragraph")
    }
    if case .image(let url, let alt) = rows[1] {
      precondition(url.scheme == "https" && alt == "illustration")
    } else {
      fatalError("missing image")
    }
    guard case .quote = rows[2], case .code("<code>") = rows[3] else {
      fatalError("quote/code lost")
    }
    let motion = ArticleBody.opus([
      [
        "pic": [
          "pics": [
            [
              "url": "//i0.hdslb.com/bfs/album/frame.jpg",
              "live_url": "http://upos.example.org/motion.mp4",
            ],
            ["url": "https://example.org/plain.jpg"],
          ]
        ]
      ]
    ])
    guard motion.count == 2, case .motion(let p, _) = motion[0], case .image = motion[1] else {
      fatalError("live-photo pair lost")
    }
    precondition(
      p.motion?.absoluteString == "https://upos.example.org/motion.mp4"
        && p.display(quality: 30).lastPathComponent == "frame.jpg@30q.webp")
    precondition(
      p.display(quality: 100) == p.url
        && GalleryPicture(URL(string: "https://example.org/a.jpg")!).display(quality: 30)
          .lastPathComponent == "a.jpg"
    )
    let sized = GalleryPicture(URL(string: "https://i0.hdslb.com/path/a.jpg@320w_180h.webp")!)
    precondition(
      sized.display(quality: 10, minimum: 50).lastPathComponent == "a.jpg@320w_180h_50q.webp")
    precondition(GalleryPicture(["src": "https://user@i0.hdslb.com/p.jpg"]) == nil)
    precondition(
      ArticleBody.originalHTMLImage("//i0.hdslb.com/a.jpg@320w_180h.webp")?.lastPathComponent
        == "a.jpg")
    precondition(
      ArticleBody.originalHTMLImage("https://example.org/a.jpg@320w.webp")?.lastPathComponent
        == "a.jpg@320w.webp")
    let rich = ArticleBody.opus([
      ["heading": ["nodes": [["word": ["words": "Title"]]]]],
      ["pic": ["pics": [["url": "//img.example.org/p.jpg"]]]],
      ["blockquote": ["children": [["text": ["nodes": [["word": ["words": "Q"]]]]]]]],
    ])
    guard rich.count == 3, case .heading = rich[0], case .image = rich[1], case .quote = rich[2]
    else { fatalError("opus contract") }
    print("Native HTML and opus reading order, links, images, quotation and code passed")
  }
}
