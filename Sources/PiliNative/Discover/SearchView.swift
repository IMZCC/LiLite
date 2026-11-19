import SwiftUI
import UniformTypeIdentifiers

/// The search page, laid out as in the official app: back, the field and 搜索 on one row, then
/// history and trending words; typing lists suggestions, and a search shows its results under
/// the section bar. The field is the app's own rather than the system search bar, so every
/// search lowers the keyboard and no collapsing search drawer fights the section bar for the top.
struct SearchView: View {
  var initialHint: String
  /// The search tab or a sheet: the page brings its own navigation stack. Everywhere else it is
  /// pushed onto the stack it was opened from (a stack inside a pushed page can hang SwiftUI).
  let standalone: Bool
  init(initialHint: String = "", keyword: String? = nil, standalone: Bool = false) {
    self.initialHint = initialHint
    self.standalone = standalone
    _draft = State(initialValue: keyword ?? "")
    _term = State(initialValue: keyword ?? "")
  }
  @Environment(\.isPresented) private var presented
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("search.defaultWord") private var useHint = false
  @AppStorage("search.hot") private var showHot = true
  @AppStorage("search.picks") private var showPicks = true
  @AppStorage("search.suggest") private var suggest = true
  @AppStorage("search.history") private var history = Data()
  @AppStorage("search.save") private var saveHistory = true
  @State private var hint = ""
  @State private var destination: SharedLink?
  @State private var resolveTask: Task<Void, Never>?
  @State private var resolvingDraft: String?
  @State private var recent = [String]()
  @State private var issue: String?
  @State private var draft = ""
  @State private var term = ""
  @State private var domain = SearchDomain.mixed
  @State private var suggestions = [String]()
  @State private var videoFilters = [SearchDomain: VideoSearchOptions]()
  @State private var otherFilters = [SearchDomain: OtherSearchOptions]()
  @State private var showFilter = false
  @State private var counts = [SearchDomain: Int]()
  @State private var numericOpened: String?
  @State private var confirmClear = false
  @State private var showImporter = false
  @State private var showExporter = false
  @State private var exportFile: SearchHistoryFile?
  @State private var openLink = false
  @State private var focused = false
  @State private var autoFocused = false
  private var owner: String { accounts.state.owner(.role(.recommend)) ?? "" }
  private var typed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
  /// Words typed but not searched yet: list suggestions over the page.
  private var suggesting: Bool { !typed.isEmpty && typed != term }
  private var prompt: String { useHint && !hint.isEmpty ? hint : "输入关键词或粘贴链接" }
  private func effectiveDomain(_ section: SearchDomain) -> SearchDomain {
    section == .mixed && (videoFilters[section] ?? VideoSearchOptions()).filtered ? .video : section
  }
  private func fields(_ section: SearchDomain) -> [String: String] {
    switch effectiveDomain(section) {
    case .video: return (videoFilters[section] ?? VideoSearchOptions()).fields()
    case .mixed: return [:]
    default: return (otherFilters[section] ?? OtherSearchOptions()).fields(section)
    }
  }
  private func identity(_ section: SearchDomain) -> String {
    [
      owner, term, section.rawValue,
      fields(section).sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: ","),
    ].joined(separator: "\n")
  }
  private func videoBinding(_ section: SearchDomain) -> Binding<VideoSearchOptions> {
    Binding(get: { videoFilters[section] ?? VideoSearchOptions() }, set: { videoFilters[section] = $0 })
  }
  private func otherBinding(_ section: SearchDomain) -> Binding<OtherSearchOptions> {
    Binding(get: { otherFilters[section] ?? OtherSearchOptions() }, set: { otherFilters[section] = $0 })
  }
  var body: some View {
    if standalone { PiliNavigationStack { page } } else { page }
  }
  private var page: some View {
    // Plain rows rather than safe-area bars, so the lists start under the field and the
    // section bar instead of scrolling beneath them.
    VStack(spacing: 0) {
      header
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
      .background(Color(uiColor: .systemBackground))
      .piliTabRoot(.search)
      .navigationTitle(term.isEmpty ? "搜索" : term)
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(isPresented: $openLink) { OpenSharedLink() }
      .navigationDestination(item: $destination) { LinkDestination(item: $0) }
      .alert("搜索", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
      .confirmationDialog("清空搜索历史？", isPresented: $confirmClear, titleVisibility: .visible) {
        Button("清空", role: .destructive) { changeHistory(.clear) }
      }
      .piliSheet(isPresented: $showFilter) {
        SearchFilterForm(domain: domain, videos: videoBinding(domain), others: otherBinding(domain))
      }
      .onAppear {
        // Opening search goes straight to typing, once the push has settled.
        guard !autoFocused else { return }
        autoFocused = true
        guard term.isEmpty else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(standalone ? 60 : 380))
          focused = true
        }
      }
      .onDisappear { cancelResolution() }
      .task(id: history) {
        let bytes = history
        let first = await Task.detached(priority: .userInitiated) { SearchHistoryStore.preview(bytes) }.value
        if !Task.isCancelled { recent = first }
      }
      .task(id: "\(useHint):\(owner)") {
        hint = useHint ? initialHint : ""
        guard useHint else { return }
        if let s = try? await BiliAPI.shared.defaultSearchWord(owner: owner), !Task.isCancelled {
          hint = s
        }
      }
      .task(id: "\(suggest):\(typed):\(owner):\(term)") {
        let q = typed
        guard suggest, !q.isEmpty, q != term else { suggestions = []; return }
        do {
          try await Task.sleep(for: .milliseconds(200))
          let r = try await BiliAPI.shared.searchSuggestions(q, owner: owner)
          try Task.checkCancellation()
          suggestions = r
        } catch {}
      }
      .onChange(of: focused) { _, now in
        // Leaving an emptied field on a results page puts the searched words back.
        if !now, typed.isEmpty, !term.isEmpty { draft = term }
      }
      .onChange(of: draft) { _, new in
        if let resolvingDraft, new != resolvingDraft { cancelResolution() }
      }
      .onChange(of: term) { _, _ in
        counts = [:]
        numericOpened = nil
      }
      .onChange(of: owner) { _, _ in
        cancelResolution()
        counts = [:]
        numericOpened = nil
        videoFilters = [:]
        otherFilters = [:]
      }
      .fileExporter(
        isPresented: $showExporter, document: exportFile, contentType: .json,
        defaultFilename: "search"
      ) { result in if case .failure(let e) = result { issue = e.localizedDescription } }
      .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText]) {
        result in
        Task {
          do {
            let url = try result.get()
            let bytes = try await Task.detached(priority: .userInitiated) {
              let scoped = url.startAccessingSecurityScopedResource()
              defer { if scoped { url.stopAccessingSecurityScopedResource() } }
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
              guard (size ?? 0) <= SearchHistoryStore.importLimit else { throw ServiceError("文件过大") }
              let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
              return try file.read(upToCount: SearchHistoryStore.importLimit + 1) ?? Data()
            }.value
            changeHistory(.replace(bytes))
          } catch { issue = error.localizedDescription }
        }
      }
  }
  /// Results stay alive under the start page and the suggestions while the words are edited.
  private var content: some View {
    ZStack {
      if !term.isEmpty { results }
      // Opaque down to the screen's edge, so the results never show through the keyboard.
      if suggesting {
        suggestionList.background { Color(uiColor: .systemBackground).ignoresSafeArea() }
      } else if term.isEmpty || (focused && typed.isEmpty) {
        landing.background { Color(uiColor: .systemBackground).ignoresSafeArea() }
      }
    }
    .background {
      // There is no navigation bar on this page: a swipe to the right goes Back. The results'
      // section pager brings its own (from its edge, once past the first section).
      if term.isEmpty && !standalone { LeadingEdgeNavigation(fullWidth: true).frame(width: 0, height: 0) }
    }
  }
  private var header: some View {
    HStack(spacing: 10) {
      if presented {
        Button {
          focused = false
          dismiss()
        } label: {
          Image(systemName: standalone ? "xmark" : "chevron.left").font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .piliGlass(in: Circle(), interactive: true)
        .accessibilityLabel(standalone ? "关闭" : "返回")
      }
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        SearchFieldBox(text: $draft, focused: $focused, prompt: prompt) { submitTyped($0) }
        if !draft.isEmpty {
          Button {
            draft = ""
            focused = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
              .frame(width: 28, height: 36).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("清除")
        }
      }
      .font(.subheadline)
      .padding(.leading, 14).padding(.trailing, draft.isEmpty ? 14 : 6).frame(height: 44)
      .contentShape(Capsule())
      .onTapGesture { focused = true }
      .piliGlass(in: Capsule(), interactive: true)
      Menu {
        options
      } label: {
        Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44).contentShape(Circle())
      } primaryAction: {
        submitTyped(draft)
      }
      .buttonStyle(.plain).foregroundStyle(.primary)
      .piliGlass(in: Circle(), interactive: true)
      .accessibilityLabel("搜索").accessibilityHint("长按查看搜索选项")
    }
    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
  }
  @ViewBuilder private var options: some View {
    Button {
      saveHistory.toggle()
    } label: {
      Label(saveHistory ? "切换为无痕搜索" : "开启搜索记录", systemImage: saveHistory ? "eye.slash" : "clock")
    }
    Menu("搜索历史") {
      Button("从文件导入") { showImporter = true }
      Button("导出到文件") {
        Task { exportFile = SearchHistoryFile(data: await SearchHistoryStore.snapshot()); showExporter = true }
      }
      Button("从剪贴板导入") {
        changeHistory(.replace(Data((UIPasteboard.general.string ?? "").utf8)))
      }
      Button("复制到剪贴板") {
        Task {
          let data = await SearchHistoryStore.snapshot()
          let text = await Task.detached { String(decoding: data, as: UTF8.self) }.value
          UIPasteboard.general.string = text
        }
      }
    }
    Button("打开链接或视频编号", systemImage: "link") { focused = false; openLink = true }
    NavigationLink("设置") { SettingsView() }
  }
  /// Typed words: open a UID or a link directly, otherwise the server's completions.
  private var suggestionList: some View {
    List {
      if let n = SearchNumber.positive(typed) {
        Button {
          focused = false
          destination = .creator(n)
        } label: {
          suggestionRow("访问 UID \(n)", symbol: "person.crop.circle", tint: .accentColor)
        }
      }
      if SharedResolver.candidate(typed) != nil {
        Button { submit(typed) } label: { suggestionRow("打开链接", symbol: "link", tint: .accentColor) }
      } else {
        Button { submit(typed) } label: {
          suggestionRow("搜索“\(typed)”", symbol: "magnifyingglass", tint: .accentColor)
        }
      }
      ForEach(suggestions.filter { $0 != typed }, id: \.self) { word in
        Button { submit(word) } label: {
          suggestionRow(word, symbol: "magnifyingglass", tint: .secondary).padding(.trailing, 40)
        }
        .overlay(alignment: .trailing) {
          // Puts the word in the field to keep typing, as the official app's arrow does.
          Button {
            draft = word
            focused = true
          } label: {
            Image(systemName: "arrow.up.left").foregroundStyle(.tertiary)
              .frame(width: 36, height: 36).contentShape(Rectangle())
          }.buttonStyle(.borderless).accessibilityLabel("填入 \(word)")
        }
      }
    }
    .font(.subheadline).foregroundStyle(.primary).buttonStyle(.plain)
    .listStyle(.plain)
    .scrollDismissesKeyboard(.immediately)
  }
  private func suggestionRow(_ text: String, symbol: String, tint: Color) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
      Text(text).lineLimit(1)
      Spacer(minLength: 0)
    }.contentShape(Rectangle())
  }
  /// Search home in the original client's arrangement: history chips, then two-column lists of
  /// trending and suggested keywords.
  private var landing: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        if useHint, !hint.isEmpty, draft.isEmpty {
          Button { submit(hint) } label: {
            Label(hint, systemImage: "magnifyingglass").font(.subheadline).lineLimit(1)
          }.piliGlassButton()
        }
        if !saveHistory {
          Label("无痕搜索中，不会记录搜索历史", systemImage: "eye.slash")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if !recent.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("搜索历史").font(.headline)
              Spacer()
              Button { confirmClear = true } label: {
                Image(systemName: "trash").font(.subheadline).foregroundStyle(.secondary)
                  .frame(width: 32, height: 28).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityLabel("清空搜索历史")
            }
            WrappingActions(spacing: 8, rowSpacing: 8) {
              ForEach(recent, id: \.self) { w in
                Button { submit(w) } label: {
                  Text(w).font(.subheadline).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }.buttonStyle(.plain).contextMenu { deleteWord(w) }
              }
            }
          }
        }
        if showHot {
          SearchSuggestionsSection(owner: owner, hot: true, select: submit).id("hot:" + owner)
        }
        if showPicks {
          SearchSuggestionsSection(owner: owner, hot: false, select: submit).id("picks:" + owner)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollDismissesKeyboard(.immediately)
  }
  private func deleteWord(_ w: String) -> some View {
    Button("删除", role: .destructive) {
      changeHistory(.remove(w))
    }
  }
  private var results: some View {
    VStack(spacing: 0) {
      domainBar
      Divider().opacity(0.5)
      // A fixed viewport, as on the home page: sized by its own pages the pager grew taller than
      // the space left under the bars and pushed them off the top of the screen.
      GeometryReader { proxy in
        RetainedDeck(choices: SearchDomain.tabs, selection: $domain, viewport: proxy.size) { section in
          resultList(section).id(identity(section))
        }.id(owner + "\n" + term)
      }
    }
    .scrollDismissesKeyboard(.immediately)
  }
  private var domainBar: some View {
    HStack(spacing: 4) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(SearchDomain.tabs, id: \.self) { d in
              let current = domain == d
              Button {
                TouchFeedback.light()
                withAnimation(.snappy(duration: 0.25)) { domain = d }
              } label: {
                HStack(spacing: 4) {
                  Text(d.rawValue)
                  if let n = counts[d] {
                    Text(n > 99 ? "99+" : "\(n)").font(.caption2).monospacedDigit()
                      .foregroundStyle(.secondary)
                  }
                }
                .font(.subheadline.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? Color.primary : Color.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                  if current { Capsule().fill(Color(uiColor: .tertiarySystemFill)) }
                }
                .contentShape(Capsule())
              }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : []).id(d)
            }
          }.padding(.horizontal, 16)
        }
          .onChange(of: domain, initial: true) { _, d in withAnimation(.snappy) { proxy.scrollTo(d, anchor: .center) } }
      }
      if [.mixed, .creator, .article].contains(domain) {
        Button {
          showFilter = true
        } label: {
          Image(systemName: "line.3.horizontal.decrease")
        }.piliGlassButton().accessibilityLabel("筛选").padding(.trailing, 16)
      }
    }.padding(.vertical, 6)
  }
  private func resultList(_ section: SearchDomain) -> some View {
    let key = identity(section)
    let t = term
    let effective = effectiveDomain(section)
    let parameters = fields(section)
    let reader = owner
    return PageList(empty: "没有匹配结果",autoMore:true,discoveryArchive:{(hit:SearchHit)->Video? in if case .video(let v)=hit.content{return v};return nil}) { cursor in
      let page = Int(cursor ?? "1") ?? 1
      let p = try await BiliAPI.shared.searchPage(
        t, domain: effective, page: page, fields: parameters, owner: reader)
      try Task.checkCancellation()
      if page == 1, key == identity(section) {
        counts[section] = p.reportedTotal
        if domain == section, typed == t, !focused, effective == .video || effective == .mixed,
          let n = SearchNumber.matched(t, rows: p.items), numericOpened != reader + "\n" + t
        {
          numericOpened = reader + "\n" + t
          destination = .archive(n, nil)
        }
      }
      return p
    } row: {
      SearchHitRow(hit: $0)
    }
  }
  private func changeHistory(_ change: SearchHistoryStore.Change) {
    SearchHistoryStore.enqueue(change) { issue = $0.localizedDescription }
  }
  private func cancelResolution() {
    resolveTask?.cancel()
    resolveTask = nil
    resolvingDraft = nil
  }
  /// 搜索 on the keyboard or the bar: the typed words, or the suggested word when empty.
  private func submitTyped(_ text: String) {
    let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
    submit(q.isEmpty && useHint ? hint : q)
  }
  private func submit(_ input: String) {
    // Every search lowers the keyboard, as in the official app.
    focused = false
    let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    cancelResolution()
    issue = nil
    if let link = SharedResolver.candidate(q) {
      draft = q
      resolvingDraft = q
      resolveTask = Task { @MainActor in
        defer { if !Task.isCancelled { resolvingDraft = nil; resolveTask = nil } }
        do {
          let target = try await link.resolve()
          try Task.checkCancellation()
          guard draft == q else { return }
          destination = target
        } catch { if !Task.isCancelled && draft == q { issue = error.localizedDescription } }
      }
      return
    }
    if q != term {
      videoFilters = [:]
      otherFilters = [:]
      counts = [:]
      numericOpened = nil
    }
    draft = q
    term = q
    if saveHistory {
      changeHistory(.record(q))
    }
  }
}

/// A one-line search field on UIKit's text field: the keyboard rises and falls exactly when asked
/// (SwiftUI focus in bars is unreliable on older systems), and Chinese input keeps its marked
/// text while composing instead of being overwritten by the binding.
struct SearchFieldBox: UIViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  let prompt: String
  let submit: (String) -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UITextField {
    let field = UITextField()
    field.font = .preferredFont(forTextStyle: .subheadline)
    field.adjustsFontForContentSizeCategory = true
    field.returnKeyType = .search
    field.enablesReturnKeyAutomatically = false
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.spellCheckingType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.clearButtonMode = .never
    field.delegate = context.coordinator
    field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }
  func updateUIView(_ field: UITextField, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    if field.markedTextRange == nil, field.text != text { field.text = text }
    if field.placeholder != prompt { field.placeholder = prompt }
    if focused != field.isFirstResponder {
      // Outside the view update: becoming first responder reports back through the delegate.
      DispatchQueue.main.async { [weak field, weak coordinator] in
        guard let field, let want = coordinator?.parent?.focused, want != field.isFirstResponder else { return }
        if want {
          if field.window != nil { field.becomeFirstResponder() }
        } else {
          field.resignFirstResponder()
        }
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 200, height: 36)
  }
  static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
    coordinator.parent = nil
  }
  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: SearchFieldBox?
    @objc func edited(_ field: UITextField) {
      // Pinyin still being composed is not text yet.
      guard field.markedTextRange == nil else { return }
      let value = field.text ?? ""
      if parent?.text != value { parent?.text = value }
    }
    func textFieldDidBeginEditing(_ field: UITextField) {
      if parent?.focused == false { parent?.focused = true }
    }
    func textFieldDidEndEditing(_ field: UITextField) {
      let value = field.text ?? ""
      if parent?.text != value { parent?.text = value }
      if parent?.focused == true { parent?.focused = false }
    }
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      let value = field.text ?? ""
      if parent?.text != value { parent?.text = value }
      field.resignFirstResponder()
      parent?.submit(value)
      return false
    }
  }
}

/// The search row a list page opens from its toolbar's magnifier, above the page's own chips.
struct LibrarySearchRow: View {
  @Binding var text: String
  @Binding var focused: Bool
  let prompt: String
  let submit: (String) -> Void
  let cancel: () -> Void
  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        SearchFieldBox(text: $text, focused: $focused, prompt: prompt, submit: submit)
        if !text.isEmpty {
          Button {
            text = ""
            submit("")
            focused = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
              .frame(width: 28, height: 34).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("清除")
        }
      }
      .font(.subheadline)
      .padding(.leading, 12).padding(.trailing, text.isEmpty ? 12 : 4).frame(height: 38)
      .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
      .contentShape(Capsule())
      .onTapGesture { focused = true }
      Button("取消") {
        focused = false
        cancel()
      }.font(.subheadline).buttonStyle(.plain).foregroundStyle(.tint)
    }
    .padding(.horizontal, 16).padding(.vertical, 6)
  }
}
private struct SearchHistoryFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
private struct SearchSuggestionsSection: View {
  let owner: String, hot: Bool, select: (String) -> Void
  @State private var data = [BiliAPI.Trend]()
  @State private var attempt = 0
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Text(hot ? "大家都在搜" : "猜你想搜").font(.headline)
        Spacer()
        Button { attempt += 1 } label: {
          Label(hot ? "刷新" : "换一换", systemImage: "arrow.clockwise").font(.footnote)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
        if hot {
          NavigationLink { TrendingSearchPage(select: select) } label: {
            HStack(spacing: 2) {
              Text("完整榜单")
              Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }.font(.footnote)
          }.buttonStyle(.plain).foregroundStyle(.tint)
        }
      }
      if let issue {
        HStack {
          Text(issue).font(.caption).foregroundStyle(.secondary)
          Button("重试") { attempt += 1 }.font(.caption)
        }
      }
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
        alignment: .leading, spacing: 14) {
        ForEach(Array(data.enumerated()), id: \.element.id) { index, t in
          Button { select(t.keyword) } label: {
            HStack(spacing: 8) {
              if hot {
                Text("\(index + 1)").font(.subheadline.weight(.bold)).monospacedDigit()
                  .lineLimit(1).fixedSize().frame(minWidth: 22, alignment: .leading)
                  .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary).frame(width: 18)
              }
              Text(t.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
              if t.show_live_icon == true {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.pink)
              }
              if let u = t.icon.flatMap(httpsURL) {
                SiteThumbnail(url: u) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                  .frame(maxWidth: 26, maxHeight: 14)
              }
              Spacer(minLength: 0)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
      .animation(.easeOut(duration: 0.2), value: data.map(\.id))
    }
    .task(id: attempt) {
      issue = nil
      do {
        let r: [BiliAPI.Trend]
        if hot {
          r = try await BiliAPI.shared.trends(owner: owner).list ?? []
        } else {
          r = try await BiliAPI.shared.searchPicks(owner: owner)
        }
        try Task.checkCancellation()
        data = r
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}
