import SwiftUI

struct ProfileOverview: View {
  let uid: String, profile: AccountProfile?, stat: ProfileStatistics?
  let navigate: (ProfileDestination) -> Void
  @EnvironmentObject private var accounts: AccountContext
  @State private var addAccount = false
  var body: some View {
    let person = profile.flatMap { String($0.mid) == uid ? $0 : nil }
    VStack(spacing: 18) {
      Button { navigate(.space(uid, person?.uname ?? "我的空间")) } label: {
        VStack(spacing: 10) {
          // The frame is 1.75x the avatar; the list row clips, so the row reserves its overhang.
          ProfileAvatar(url: person?.face.flatMap(httpsURL), size: 88, pendant: person?.pendantURL,
            reservesPendant: true)
            .padding(.vertical, 10)
          VStack(spacing: 4) {
            Text(person?.uname ?? accounts.state.accounts.first(where: { $0.id == uid })?.label ?? "当前账号")
              .font(.title2.weight(.bold)).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 6) {
              if let level = person?.level_info?.current_level {
                UserLevelBadge(level: Int(level), height: 14, hardcore: person?.is_senior_member == 1)
              }
              if (person?.vipStatus ?? 0) > 0 {
                Text(person?.vipType == 2 ? "年度大会员" : "大会员").font(.caption.weight(.semibold))
                  .foregroundStyle(.pink).padding(.horizontal, 7).padding(.vertical, 2)
                  .background(Color.pink.opacity(0.14), in: Capsule())
              }
              if person?.is_senior_member == 1 {
                Text("硬核会员").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              }
            }
            Text("UID " + uid).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
          }
        }.frame(maxWidth: .infinity).contentShape(Rectangle())
      }.buttonStyle(.plain).contextMenu { Button("登录其他账号") { addAccount = true } }
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          if Int64(uid) != nil {
            Button { navigate(.dynamics(uid)) } label: {
              count("动态", stat?.dynamic_count)
            }
            Divider().frame(height: 28)
          }
          Button { navigate(.relations(uid, fans: false)) } label: {
            count("关注", stat?.following)
          }
          Divider().frame(height: 28)
          Button { navigate(.relations(uid, fans: true)) } label: {
            count("粉丝", stat?.follower)
          }
        }.buttonStyle(.plain).padding(.vertical, 14)
        if person?.money != nil || person?.level_info?.current_exp != nil {
          Divider().padding(.horizontal, 16)
          VStack(spacing: 8) {
            HStack(spacing: 12) {
              accountBalance(person)
              Spacer(minLength: 0)
              accountExperience(person)
            }.font(.footnote).foregroundStyle(.secondary)
            if let exp = person?.level_info?.current_exp, let next = person?.level_info?.next, next > 0 {
              Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(height: 4)
                .overlay(alignment: .leading) {
                  GeometryReader { g in
                    Capsule().fill(Color.accentColor)
                      .frame(width: g.size.width * min(1, max(0, Double(exp) / Double(next))))
                  }
                }
                .accessibilityElement().accessibilityLabel("等级经验").accessibilityValue("\(exp)/\(next)")
            }
          }.padding(.horizontal, 16).padding(.vertical, 12)
        }
      }
      .background(Color(uiColor: .secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: NativeGlass.panelRadius, style: .continuous))
    }.piliSheet(isPresented: $addAccount) {
      PiliNavigationStack { QRLoginView().toolbar { Button("关闭") { addAccount = false } } }
    }
  }
  @ViewBuilder private func accountBalance(_ person: AccountProfile?) -> some View {
    if let coins = person?.money {
      Label("\(coins.formatted()) 硬币", systemImage: "circle.circle").labelStyle(.titleAndIcon)
    }
  }
  @ViewBuilder private func accountExperience(_ person: AccountProfile?) -> some View {
    if let exp = person?.level_info?.current_exp, let next = person?.level_info?.next, next > 0 {
      Text("经验 \(exp)/\(next)").monospacedDigit()
    }
  }
  private func count(_ text: String, _ n: Int?) -> some View {
    VStack(spacing: 5) {
      Text(n.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
        .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
      Text(text).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}
struct ProfileQuickActions: View {
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage(NavigationLayout.key) private var pageLayout = Data()
  @State private var privacy = false
  private var anonymous: Bool { accounts.state.owner(.role(.heartbeat)) == nil }
  var body: some View {
    Menu {
      if !NavigationLayout.read(pageLayout).tabs.contains(.home) {
        NavigationLink("搜索") { DeferredPage { SearchView() } }
      }
      if let uid = accounts.state.active {
        NavigationLink("我的评论") { DeferredPage { MyReplies(uid: uid) } }
        Button(anonymous ? "退出无痕模式" : "进入无痕模式") {
          if anonymous { set(false, permanent: true, uid: uid) } else { privacy = true }
        }
      }
      if !accounts.state.accounts.isEmpty {
        Menu("切换账号") {
          ForEach(accounts.state.accounts) { account in
            Button {
              Task { await accounts.select(account.id) }
            } label: {
              if account.id == accounts.state.active {
                Label(account.label, systemImage: "checkmark")
              } else {
                Text(account.label)
              }
            }
          }
        }
      }
      Picker("外观", selection: $appearance) {
        Text("浅色").tag("light")
        Text("深色").tag("dark")
        Text("跟随系统").tag("system")
      }
      NavigationLink("设置") { DeferredPage { SettingsView() } }
    } label: {
      Label("我的选项", systemImage: anonymous && accounts.state.active != nil ? "eye.slash" : "ellipsis")
        .labelStyle(.iconOnly)
    }
    .confirmationDialog("无痕浏览", isPresented: $privacy) {
      if let owner = accounts.state.active {
        Button("仅本次") { set(true, permanent: false, uid: owner) }
        Button("保存为默认") { set(true, permanent: true, uid: owner) }
      }
    }
  }
  private func set(_ on: Bool, permanent: Bool, uid: String) {
    Task {
      do {
        try await AccountJar.shared.privatePlayback(on, permanent: permanent, owner: uid)
        await accounts.refresh()
      } catch { accounts.issue = error.localizedDescription }
    }
  }
}
