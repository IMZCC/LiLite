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
  @State private var status: Bool?
  @State private var contribution: String?
  @Environment(\.dismiss) private var dismiss
  private static let modeNames = ["总是跳过", "跳过一次", "手动跳过", "仅显示", "禁用"]
  var body: some View {
    Form {
      Section {
        SettingToggle(title: "使用空降助手", symbol: "airplane.departure", color: .green, isOn: $enabled)
          .settingAnchor("SponsorSettings/使用空降助手")
        if enabled {
          Button { Task { await check() } } label: {
            HStack {
              SettingsRowLabel(title: "服务器状态", symbol: "server.rack", color: .gray)
              Spacer()
              switch status {
              case nil: ProgressView()
              case true?: Label("正常", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
              case false?: Label("不可用", systemImage: "xmark.circle.fill").foregroundStyle(.red)
              }
            }
            .labelStyle(.titleAndIcon).font(.callout)
          }.settingAnchor("SponsorSettings/检查连接")
        }
      } footer: {
        Text("基于 BilibiliSponsorBlock 社区标注，自动跳过赞助、片头片尾等片段")
      }
      if enabled {
        Section {
          HStack {
            SettingsRowLabel(title: "最短片段时长", symbol: "timer", color: .orange)
            Spacer(minLength: 12)
            TextField("最短自动跳过时长（秒）", value: $rules.minimum, format: .number, prompt: Text("0"))
              .settingAnchor("SponsorSettings/最短自动跳过时长（秒）").keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing).monospacedDigit().frame(maxWidth: 70)
            Text("秒").foregroundStyle(.secondary)
          }
          SettingToggle(title: "显示跳过提示", symbol: "text.bubble", color: .blue, isOn: $rules.toast)
            .settingAnchor("SponsorSettings/显示跳过提示")
          SettingToggle(title: "向服务器统计跳过次数", symbol: "chart.bar", color: .teal, isOn: $rules.track)
            .settingAnchor("SponsorSettings/向服务器统计跳过次数")
          Button {
            Task {
              do {
                let r = try await SponsorAPI(address).stats()
                contribution = "提交 \(r.segmentCount) 段 · 使用 \(r.viewCount) 次 · 节省 \(r.minutesSaved.formatted(.number.precision(.fractionLength(0)))) 分钟"
              } catch { contribution = error.localizedDescription }
            }
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              SettingsRowLabel(title: "我的贡献", symbol: "person.crop.circle.badge.checkmark", color: .indigo)
              if let contribution {
                Text(contribution).font(.caption).foregroundStyle(.secondary).padding(.leading, 44)
              }
            }
          }.settingAnchor("SponsorSettings/我的贡献")
        } footer: {
          Text("短于此时长的片段不会被自动跳过")
        }
        Section {
          ForEach(Array(SponsorCategory.all.enumerated()), id: \.element.id) { i, c in
            let mode = rules.modes[i]
            let color = Color(sponsorRGB: rules.colors[i].isEmpty ? c.rgb : rules.colors[i])
            HStack(spacing: 12) {
              NavigationLink {
                SponsorCategoryColor(title: c.title, fallback: c.rgb, hex: $rules.colors[i])
              } label: {
                HStack(spacing: 10) {
                  Circle().fill(color).frame(width: 12, height: 12)
                    .overlay { Circle().stroke(.separator, lineWidth: 0.5) }
                  Text(c.title).foregroundStyle(mode == 4 ? .secondary : .primary)
                }
              }
              Menu {
                Picker("处理方式", selection: $rules.modes[i]) {
                  ForEach(Array(Self.modeNames.enumerated()), id: \.offset) { n, s in Text(s).tag(n) }
                }
              } label: {
                HStack(spacing: 3) {
                  Text(Self.modeNames[min(max(mode, 0), 4)])
                  Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.subheadline).foregroundStyle(mode == 4 ? Color.secondary : Color.accentColor)
              }
              .fixedSize()
            }
          }
        } header: {
          Text("片段类型")
        } footer: {
          Text("点按类型可修改标记颜色")
        }
        .settingAnchor("SponsorSettings/片段行为")
        Section {
          SecureField("迁移贡献 ID", text: $identity).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("复制本机贡献 ID") {
            do {
              UIPasteboard.general.string = try SponsorIdentity.get(SponsorAPI(address).base)
              result = "已复制"
            } catch { result = error.localizedDescription }
          }.settingAnchor("SponsorSettings/复制本机贡献 ID")
        } header: {
          Text("用户 ID")
        } footer: {
          Text("填入其他设备的贡献 ID 后保存，可沿用原有的贡献记录")
        }
        Section {
          TextField("服务地址", text: $address).settingAnchor("SponsorSettings/服务地址").keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("恢复默认地址") { address = SponsorAPIRequest.defaultServer; result = nil }
            .settingAnchor("SponsorSettings/恢复默认地址")
          if let base = try? SponsorAPI(address).base, let origin = PrivateServiceOrigin(.sponsor,base) {
            NavigationLink("服务器证书") { PrivateTrustPanel(origin:origin).id(origin) }.settingAnchor("SponsorSettings/服务器证书")
          }
        } header: {
          Text("服务器地址")
        } footer: {
          if let result { Text(result) }
        }
        Section {
          Link(destination: URL(string: "https://github.com/hanydd/BilibiliSponsorBlock")!) {
            VStack(alignment: .leading, spacing: 2) {
              Text("关于空降助手").foregroundStyle(.primary)
              Text("github.com/hanydd/BilibiliSponsorBlock").font(.caption).foregroundStyle(.secondary)
            }
          }.settingAnchor("SponsorSettings/关于空降助手")
        }
      }
    }
    .navigationTitle("空降助手").navigationBarTitleDisplayMode(.inline)
    .onAppear { if address.isEmpty { address = server } }
    .task(id: enabled) { if enabled { await check() } }
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
  @MainActor private func check() async {
    status = nil
    do {
      try await SponsorAPI(address.isEmpty ? server : address).status()
      status = true
    } catch { status = false; result = error.localizedDescription }
  }
}

/// Marker colour for one segment type: preset swatches plus a hex field.
private struct SponsorCategoryColor: View {
  let title: String, fallback: String
  @Binding var hex: String
  private static let swatches = [
    "00d400", "ffff00", "008a5c", "cc00ff", "ff1684", "00ffff", "0202ed", "008fd6", "222222",
    "7300ff", "ff9900", "e53935", "ffffff", "fb7299",
  ]
  var body: some View {
    Form {
      Section {
        HStack {
          Spacer()
          Capsule().fill(Color(sponsorRGB: hex.isEmpty ? fallback : hex)).frame(width: 180, height: 8)
          Spacer()
        }.padding(.vertical, 8)
      }
      Section("预设颜色") {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), spacing: 12) {
          ForEach(Self.swatches, id: \.self) { value in
            Button { hex = value == fallback ? "" : value } label: {
              Circle().fill(Color(sponsorRGB: value)).frame(width: 32, height: 32)
                .overlay { Circle().stroke(.separator, lineWidth: 0.5) }
                .overlay {
                  if (hex.isEmpty ? fallback : hex).lowercased() == value {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                      .foregroundStyle(value == "ffffff" || value == "ffff00" ? .black : .white)
                  }
                }
            }.buttonStyle(.plain)
          }
        }.padding(.vertical, 6)
      }
      Section {
        TextField("标记颜色（十六进制）", text: $hex, prompt: Text(fallback)).textInputAutocapitalization(.never)
          .autocorrectionDisabled().font(.body.monospaced())
        if !hex.isEmpty { Button("恢复默认颜色") { hex = "" } }
      } header: {
        Text("十六进制")
      } footer: {
        Text("例如 \(fallback)，留空使用默认颜色")
      }
    }
    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
  }
}
struct SponsorList: View {
  @ObservedObject var model: PlayerModel
  var inlineEditor = false
  @State private var authoring = false
  @State private var message: String?
  var body: some View {
    List {
      if let message {
        Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
      }
      if let error = model.sponsorError {
        Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
      }
      ForEach(model.sponsor) { s in
        let color = Color(sponsorRGB: model.sponsorRules.color(s))
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 4)
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(s.detail?.title ?? s.category).font(.subheadline.weight(.semibold))
              Spacer()
              Text(clockText(s.segment[0]) + " – " + clockText(s.segment[1]))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
              Button("定位", systemImage: "scope") { model.seek(s.segment[0]) }
              if s.segment[1] > s.segment[0] {
                Button("跳过", systemImage: "forward.end") { model.skipSponsor(s) }
              }
              Spacer()
              Menu {
                Button("赞同", systemImage: "hand.thumbsup") { vote(s, 1, nil) }
                Button("不赞同", systemImage: "hand.thumbsdown") { vote(s, 0, nil) }
                Menu("建议修改类别") {
                  ForEach(SponsorCategory.all) { c in Button(c.title) { vote(s, nil, c.id) } }
                }
              } label: {
                Label("反馈", systemImage: "ellipsis.bubble")
              }
            }
            .font(.footnote).labelStyle(.titleAndIcon).buttonStyle(.borderless)
          }
        }
        .padding(.vertical, 2)
      }
    }
    .listStyle(.plain)
    .overlay {
      if model.sponsor.isEmpty && model.sponsorError == nil {
        ContentUnavailableView("暂无片段标记", systemImage: "bookmark.slash",
          description: Text("可以为这个视频添加第一条片段"))
      }
    }
    .navigationTitle("空降标记").navigationBarTitleDisplayMode(.inline).toolbar {
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
