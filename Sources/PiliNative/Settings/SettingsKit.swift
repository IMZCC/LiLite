import SwiftUI

/// Toggle row with the coloured icon tile used across settings.
struct SettingToggle: View {
  let title: String, symbol: String
  var color: Color = .gray
  @Binding var isOn: Bool
  var body: some View {
    Toggle(isOn: $isOn) { SettingsRowLabel(title: title, symbol: symbol, color: color) }
  }
}

/// Slider row: title (optionally with an icon) on the left, the live value on the right,
/// slider underneath. Replaces the "LabeledContent + bare Slider" pairs.
struct SettingSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 0.01
  var symbol: String? = nil
  var color: Color = .gray
  var format: (Double) -> String = { $0.formatted(.percent.precision(.fractionLength(0))) }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        if let symbol {
          SettingsRowLabel(title: title, symbol: symbol, color: color)
        } else {
          Text(title)
        }
        Spacer(minLength: 8)
        Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
          .contentTransition(.numericText(value: value))
          .animation(.snappy(duration: 0.2), value: value)
      }
      Slider(value: $value, in: range, step: step)
        .accessibilityLabel(title).accessibilityValue(format(value))
    }
    .padding(.vertical, 4)
  }
}

/// Stepper row with the value shown on the trailing side instead of baked into the title.
struct SettingStepper: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 1
  var format: (Double) -> String = { $0.formatted() }
  var body: some View {
    Stepper(value: $value, in: range, step: step) {
      HStack {
        Text(title)
        Spacer(minLength: 8)
        Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
          .contentTransition(.numericText(value: value))
          .animation(.snappy(duration: 0.2), value: value)
      }
    }
    .accessibilityValue(format(value))
  }
}

extension Binding where Value == Int {
  /// Adapts an integer setting to the Double-based rows above.
  var asDouble: Binding<Double> {
    Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) })
  }
}

/// Multi-line rule editor page (keywords, regexes, ids) with an explanatory footer.
struct SettingTextPage: View {
  let title: String, footer: String
  @Binding var text: String
  var monospaced = false
  var body: some View {
    Form {
      Section {
        TextEditor(text: $text)
          .font(monospaced ? .body.monospaced() : .body)
          .autocorrectionDisabled().textInputAutocapitalization(.never)
          .frame(minHeight: 240)
      } footer: {
        Text(footer)
      }
    }
    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
  }
}

/// Account summary at the top of settings, like the system Settings app's Apple Account row.
struct SettingsAccountCard: View {
  @EnvironmentObject private var accounts: AccountContext
  @ObservedObject private var store = ProfileStore.shared
  var body: some View {
    let uid = accounts.state.active
    let profile = uid.flatMap { id in store.profiles[id].flatMap { String($0.mid) == id ? $0 : nil } }
    let name = profile?.uname ?? uid.flatMap { id in accounts.state.accounts.first { $0.id == id }?.label }
    Group {
      if uid != nil {
        NavigationLink { SettingsAccountActions() } label: { card(profile?.face.flatMap(httpsURL), name, uid) }
      } else {
        NavigationLink { QRLoginView() } label: { card(nil, nil, nil) }
      }
    }
    .task(id: uid) { if let uid { await store.refresh(uid) } }
  }
  private func card(_ face: URL?, _ name: String?, _ uid: String?) -> some View {
    HStack(spacing: 14) {
      ProfileAvatar(url: face, size: 60)
      VStack(alignment: .leading, spacing: 3) {
        Text(name ?? (uid == nil ? "登录哔哩哔哩账号" : "当前账号"))
          .font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
        Text(uid.map { "UID \($0) · 账号、登录与切换" } ?? "扫码登录后同步关注、历史和收藏")
          .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(.vertical, 6)
  }
}
