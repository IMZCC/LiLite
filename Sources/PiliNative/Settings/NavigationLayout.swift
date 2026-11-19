import SwiftUI

extension MainTab {
  @ViewBuilder var screen: some View {
    switch self {
    case .home: FeedView()
    case .search: SearchView()
    case .dynamics: DynamicFeed()
    case .mine: ProfileView()
    }
  }
}
struct NavigationLayoutPanel: View {
  @State private var draft = NavigationLayout.current()
  @State private var message: String?
  @Environment(\.dismiss) private var dismiss
  private func addRow(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button {
      withAnimation(.snappy(duration: 0.25)) { action() }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.white, .green)
        Text(title).foregroundStyle(.primary)
      }
    }
  }
  var body: some View {
    List {
      Section {
        NavigationLink { MotionSettings() } label: {
          Label("页面动画与回弹", systemImage: "wand.and.stars").labelStyle(SettingsIconLabelStyle(color: .purple))
        }.settingAnchor("NavigationLayoutPanel/页面动画与回弹")
        Toggle(isOn: Binding(get: { !draft.directBack }, set: { draft.directBack = !$0 })) {
          Label("返回键切至首个栏目", systemImage: "arrow.uturn.backward").labelStyle(SettingsIconLabelStyle(color: .blue))
        }.settingAnchor("NavigationLayoutPanel/返回键切至首个栏目")
      } header: {
        Text("导航外观")
      }.settingAnchor("NavigationLayoutPanel/导航外观")
      Section {
        Toggle("首页搜索栏", isOn: $draft.collapseTop).settingAnchor("NavigationLayoutPanel/首页搜索栏")
        Toggle("底部导航栏", isOn: $draft.collapseBottom).settingAnchor("NavigationLayoutPanel/底部导航栏")
      } header: {
        Text("滚动时收起")
      } footer: {
        Text("底部导航栏使用系统标签栏，向下滚动时缩小为悬浮按钮。")
      }.settingAnchor("NavigationLayoutPanel/滚动时收起")
      Section {
        ForEach(draft.tabs) { t in
          Label(t.title, systemImage: t.icon)
            .deleteDisabled(draft.tabs.count <= 1)
        }
        .onMove { draft.tabs.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { idx in
          guard draft.tabs.count - idx.count >= 1 else { return }
          draft.tabs.remove(atOffsets: idx)
          if !draft.tabs.contains(draft.launch) { draft.launch = draft.tabs[0] }
        }
        ForEach(NavigationLayout.columns.filter { !draft.tabs.contains($0) }) { t in
          addRow(t.title) { draft.tabs.append(t) }
        }
        Picker("启动时打开", selection: $draft.launch) {
          ForEach(draft.tabs) { t in Text(t.title).tag(t) }
        }.settingAnchor("NavigationLayoutPanel/默认栏目")
      } header: {
        Text("主栏目")
      } footer: {
        Text("拖动右侧把手调整顺序，至少保留一个栏目。")
      }.settingAnchor("NavigationLayoutPanel/主栏目")
      .settingAnchor("NavigationLayoutPanel/启动时打开")
      Section {
        ForEach(draft.channels) { c in
          Text(c.rawValue).deleteDisabled(draft.channels.count <= 1)
        }
        .onMove { draft.channels.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { idx in
          guard draft.channels.count - idx.count >= 1 else { return }
          draft.channels.remove(atOffsets: idx)
        }
        ForEach(HomeChannel.allCases.filter { !draft.channels.contains($0) }) { c in
          addRow(c.rawValue) { draft.channels.append(c) }
        }
      } header: {
        Text("首页频道")
      }.settingAnchor("NavigationLayoutPanel/首页频道")
      Section {
        ForEach(draft.mineTabs) { tab in Text(tab.label) }
          .onMove { draft.mineTabs.move(fromOffsets: $0, toOffset: $1) }
          .onDelete { draft.mineTabs.remove(atOffsets: $0) }
        ForEach(MineSection.allCases.filter { !draft.mineTabs.contains($0) }) { tab in
          addRow(tab.label) { draft.mineTabs.append(tab) }
        }
      } header: {
        Text("我的页预览")
      } footer: {
        Text("显示在“我的”页里的内容分组。")
      }.settingAnchor("NavigationLayoutPanel/我的页预览")
      Section {
        Button("恢复默认布局", role: .destructive) {
          withAnimation(.snappy) { draft = NavigationLayout() }
        }
        .frame(maxWidth: .infinity)
        .settingAnchor("NavigationLayoutPanel/恢复默认布局")
      }
      if let message { Text(message).font(.footnote).foregroundStyle(.red) }
    }.environment(\.editMode, .constant(.active))
    .animation(.snappy(duration: 0.25), value: draft)
    .navigationTitle("导航布局").toolbar {
      Button("保存") {
        do {
          try draft.save()
          dismiss()
        } catch { message = error.localizedDescription }
      }
    }
  }
}
