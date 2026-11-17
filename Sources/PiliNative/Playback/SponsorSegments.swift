import SwiftUI

extension Color {
  fileprivate init(sponsorRGB: String) {
    let v = Int(sponsorRGB, radix: 16) ?? 0x888888
    self.init(
      .sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255,
      blue: Double(v & 255) / 255, opacity: 1)
  }
}
struct SponsorSettings: View {
  @AppStorage("sponsor.enabled") private var enabled = false
  @AppStorage("sponsor.server") private var server = SponsorAPIRequest.defaultServer
  @State private var rules = SponsorRules.current().padded()
  @State private var address = ""
  @State private var identity = ""
  @State private var result: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Form {
      Toggle("使用空降助手", isOn: $enabled).settingAnchor("SponsorSettings/使用空降助手")
      if enabled {
        Section("片段行为") {
          TextField("最短自动跳过时长（秒）", value: $rules.minimum, format: .number).settingAnchor("SponsorSettings/最短自动跳过时长（秒）").keyboardType(.decimalPad)
          Toggle("显示跳过提示", isOn: $rules.toast).settingAnchor("SponsorSettings/显示跳过提示")
          Toggle("向服务器统计跳过次数", isOn: $rules.track).settingAnchor("SponsorSettings/向服务器统计跳过次数")
          ForEach(Array(SponsorCategory.all.enumerated()), id: \.element.id) { i, c in
            NavigationLink(c.title) {
              Form {
                Picker("处理方式", selection: $rules.modes[i]) {
                  ForEach(Array(["总是跳过", "跳过一次", "手动跳过", "仅显示", "禁用"].enumerated()), id: \.offset) {
                    n, s in Text(s).tag(n)
                  }
                }
                TextField("标记颜色（十六进制）", text: $rules.colors[i]).textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                LabeledContent("预览") {
                  Circle().fill(
                    Color(sponsorRGB: rules.colors[i].isEmpty ? c.rgb : rules.colors[i])
                  ).frame(width: 20, height: 20)
                }
              }.navigationTitle(c.title)
            }
          }
        }.settingAnchor("SponsorSettings/片段行为")
        Link("关于空降助手",destination:URL(string:"https://github.com/hanydd/BilibiliSponsorBlock")!).settingAnchor("SponsorSettings/关于空降助手")
        Section("服务器") {
          TextField("服务地址", text: $address).settingAnchor("SponsorSettings/服务地址").keyboardType(.URL).textInputAutocapitalization(
            .never
          ).autocorrectionDisabled()
          Button("恢复默认地址") { address = SponsorAPIRequest.defaultServer; result = nil }
            .settingAnchor("SponsorSettings/恢复默认地址")
          if let base = try? SponsorAPI(address).base, let origin = PrivateServiceOrigin(.sponsor,base) {
            NavigationLink("服务器证书") { PrivateTrustPanel(origin:origin).id(origin) }.settingAnchor("SponsorSettings/服务器证书")
          }
          Button("检查连接") {
            Task {
              do {
                try await SponsorAPI(address).status()
                result = "服务器可用"
              } catch { result = error.localizedDescription }
            }
          }.settingAnchor("SponsorSettings/检查连接")
          SecureField("迁移贡献 ID", text: $identity).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("复制本机贡献 ID") {
            do {
              UIPasteboard.general.string = try SponsorIdentity.get(SponsorAPI(address).base)
              result = "已复制"
            } catch { result = error.localizedDescription }
          }.settingAnchor("SponsorSettings/复制本机贡献 ID")
          Button("我的贡献") {
            Task {
              do {
                let r = try await SponsorAPI(address).stats()
                result =
                  "提交 \(r.segmentCount) 段 · 使用 \(r.viewCount) 次 · 节省 \(r.minutesSaved.formatted(.number.precision(.fractionLength(0)))) 分钟"
              } catch { result = error.localizedDescription }
            }
          }.settingAnchor("SponsorSettings/我的贡献")
        }
      }
      if let result { Text(result) }
    }.navigationTitle("空降助手").onAppear { if address.isEmpty { address = server } }
      .toolbar {
        Button("保存") {
          do {
            let api = try SponsorAPI(address)
            try rules.validate()
            if !identity.isEmpty {
              try SponsorIdentity.set(identity, base: api.base)
              identity = ""
            }
            try rules.save()
            server = address
            dismiss()
          } catch { result = error.localizedDescription }
        }
      }
  }
}
struct SponsorList: View {
  @ObservedObject var model: PlayerModel
  var inlineEditor = false
  @State private var authoring = false
  @State private var message: String?
  var body: some View {
    List {
      if let message { Text(message) }
      if let error = model.sponsorError { Text(error) }
      ForEach(model.sponsor) { s in
        VStack(alignment: .leading) {
          Label(s.detail?.title ?? s.category, systemImage: "bookmark.fill").foregroundStyle(
            Color(sponsorRGB: model.sponsorRules.color(s)))
          Text(clockText(s.segment[0]) + " – " + clockText(s.segment[1])).monospacedDigit()
          HStack {
            Button("定位") { model.seek(s.segment[0]) }.buttonStyle(.borderless)
            if s.segment[1] > s.segment[0] {
              Button("跳过") { model.skipSponsor(s) }.buttonStyle(.borderless)
            }
            Spacer()
            Menu("反馈") {
              Button("赞同") { vote(s, 1, nil) }
              Button("不赞同") { vote(s, 0, nil) }
              Menu("建议修改类别") {
                ForEach(SponsorCategory.all) { c in Button(c.title) { vote(s, nil, c.id) } }
              }
            }
          }
        }
      }
      if model.sponsor.isEmpty && model.sponsorError == nil {
        Text("暂无片段标记").foregroundStyle(.secondary)
      }
    }.navigationTitle("空降标记").toolbar {
      Button(model.sponsorDrafts.isEmpty ? "添加片段" : "编辑草稿") {
        if model.sponsorDrafts.isEmpty { model.sponsorDrafts = [.init(end: model.seconds)] }
        authoring = true
      }.disabled(
        model.timeline.source?.bvid == nil || model.duration <= 0)
    }.piliRefreshable { await model.reloadSponsors() }
      .navigationDestination(isPresented: Binding(get: { inlineEditor && authoring }, set: { if inlineEditor { authoring = $0 } })) {
        SponsorEditor(model: model, embedded: true)
      }.piliSheet(isPresented: Binding(get: { !inlineEditor && authoring }, set: { if !inlineEditor { authoring = $0 } })) { SponsorEditor(model: model) }
  }
  private func vote(_ s: SponsorSegment, _ type: Int?, _ category: String?) {
    Task {
      do {
        try await SponsorAPI().vote(s.id, type: type, category: category)
        message = "反馈已提交"
      } catch { message = error.localizedDescription }
    }
  }
}
struct SponsorMarkers: View {
  let rows: [SponsorSegment], duration: Double, rules: SponsorRules
  var body: some View {
    Canvas { ctx, sz in
      guard duration > 0 else { return }
      for s in rows where s.valid && rules.mode(s) != 4 {
        let x = min(1, s.segment[0] / duration) * sz.width
        let end = min(1, s.segment[1] / duration) * sz.width
        ctx.fill(
          Path(CGRect(x: x, y: 0, width: max(2, end - x), height: sz.height)),
          with: .color(Color(sponsorRGB: rules.color(s))))
      }
    }.frame(height: 3).accessibilityHidden(true)
  }
}
