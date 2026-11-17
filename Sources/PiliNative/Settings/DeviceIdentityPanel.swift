import SwiftUI

struct DeviceIdentityPanel: View {
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var guest = ""
  @State private var values = [String: String]()
  @State private var issue: String?
  @State private var busy = false
  var body: some View {
    Form {
      Section("游客") { field("设备标识", text: $guest) }
      ForEach(accounts.state.accounts) { user in
        Section(user.label) {
          field("设备标识", text: Binding(get: { values[user.id] ?? "" }, set: { values[user.id] = $0 }))
        }
      }
      if let issue { Text(issue).foregroundStyle(.secondary) }
    }.navigationTitle("客户端设备标识").toolbar {
      Button("保存") { Task { await save() } }.disabled(busy || guest.isEmpty)
    }.task(id: accounts.state.accounts.map(\.id)) {
      guest = MobileDeviceID.guest()
      values = Dictionary(uniqueKeysWithValues: accounts.state.accounts.map { ($0.id, MobileDeviceID.use($0.archiveDevice)) })
    }
  }
  private func field(_ label: String, text: Binding<String>) -> some View {
    TextField(label, text: text).autocorrectionDisabled().textInputAutocapitalization(.never)
      .font(.body.monospaced()).privacySensitive()
  }
  private func save() async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    do {
      try await AccountJar.shared.updateDevices(guest: guest, accounts: values)
      await accounts.refresh(); dismiss()
    } catch { issue = error.localizedDescription }
  }
}
