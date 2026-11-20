import AVKit
import SwiftUI

/// The AVKit renderer stays attached to its player. Only its picture is resized while its system
/// controls are off. Captions, hit targets and app controls continue to use the unscaled viewport.
struct Theater: View {
  let player: any PlaybackEngine
  let overlay: AnyView
  var live = false
  var showsControls = true
  var onPresentation: ((Bool) -> Void)? = nil
  var interaction: AnyView? = nil
  var caption: AnyView? = nil, marks: AnyView? = nil
  var timeline:TimelineState?=nil
  var detached = false
  var fullscreen = false
  var toggle: (() -> Void)? = nil, seek: ((Double) -> Void)? = nil, expand: (() -> Void)? = nil
  var upscale: UpscaleSession? = nil
  @Environment(\.styledSubtitles) private var scripts
  @Environment(\.playerChrome) private var slots
  @StateObject private var clock = ViewportClock()
  @StateObject private var touch = ViewportTouch()
  @AppStorage("play.gravity") private var gravity = "fit"
  @AppStorage("player.bottomProgress") private var progress = 0
  @AppStorage("player.longControls") private var longer = false
  @AppStorage("player.shrink") private var shrinks = true
  /// "延伸到边缘": the controls go to the screen's edges too.
  @AppStorage("player.edgeToEdge") private var edgeToEdge = false
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var visible = true
  @State private var editing = false
  @State private var system = false
  @State private var pipError: String?
  @State private var zoom = ViewportZoom()
  @State private var initialZoom: ViewportZoom?
  @AppStorage("player.scrollVolume") private var scrollVolume = true
  @State private var volumeHint: Int?
  @State private var routeVolume = false
  @State private var volumeSequence = 0
  @State private var pulse = 0
  /// Fullscreen: the panel open under the bar, the scrubbed time, and the brief lock offer.
  @State private var panel: String?
  @State private var scrub: Double?
  @State private var lockHint = false
  @State private var lockPulse = 0
  /// A menu opened from the chrome (speed, fit, subtitles) keeps it up until this uptime: hiding
  /// the chrome takes the menu's anchor away and closes it.
  @State private var holdUntil = 0.0
  @AppStorage("player.seekPreview") private var previews = true
  @AccessibilityFocusState private var controlsFocused: Bool
  /// The picture and its layers; `body` adds the behaviour (split for the type checker).
  private var stage: some View {
    GeometryReader { geo in
      let size = geo.size
      let chosen = PictureFit(rawValue: gravity) ?? .fit
      let canvas = chosen.geometry(view: size, source: clock.pictureSize,
        firstChoice: clock.item == nil || clock.picture.changedItem != clock.item)
      let systemGravity = chosen == .stretch ? canvas.gravity : gravity
      let frame = system ? size : canvas.size
      // Fullscreen, the picture fills the screen top to bottom as in the reference player; the
      // controls and captions keep to the safe area by these insets.
      let insets = fullscreen && !edgeToEdge ? WindowMetrics.safeInsets : EdgeInsets()
      let safe = CGSize(width: max(1, size.width - insets.leading - insets.trailing),
        height: max(1, size.height - insets.top - insets.bottom))
      ZStack {
        Color.black
        ZStack {
          if !detached {
            Group {
            if let native = player.nativePlayer {
            SystemTheater(
              player: native,
              overlay: system && !clock.picture.inPictureInPicture
                ? AnyView(
                  ZStack(alignment: .bottom) {
                    overlay
                    if let scripts{StyledSubtitleLayer(session:scripts,player:player,gravity:gravity)}
                    if let caption { caption }
                  }) : nil, live: live,
              showsControls: showsControls && system, onPresentation: onPresentation, pictureGravity: system ? systemGravity : canvas.gravity,
              pipError: { pipError = $0 }
            )
            } else if let mpv = player as? MPVPlayer {
              MPVVideoView(player: mpv, gravity: canvas.gravity)
            }
            }
            .scaleEffect(x: !system && clock.picture.mirrorX ? -1 : 1, y: !system && clock.picture.mirrorY ? -1 : 1)
            .frame(width: frame.width * zoom.scale, height: frame.height * zoom.scale)
            .position(x: size.width / 2 + zoom.x, y: size.height / 2 + zoom.y)
          }
          if !system && !clock.picture.inPictureInPicture {
            if let upscale, !detached, let native = player.nativePlayer, let item = native.currentItem {
              UpscaleLayer(
                player: native, session: upscale, item: item, gravity: canvas.gravity
              )
              .scaleEffect(x: !system && clock.picture.mirrorX ? -1 : 1, y: !system && clock.picture.mirrorY ? -1 : 1)
            .frame(width: frame.width * zoom.scale, height: frame.height * zoom.scale)
              .position(x: size.width / 2 + zoom.x, y: size.height / 2 + zoom.y)
            }
            if !detached,let scripts{StyledSubtitleLayer(session:scripts,player:player,gravity:canvas.gravity)
              .frame(width:frame.width*zoom.scale,height:frame.height*zoom.scale)
              .position(x:size.width/2+zoom.x,y:size.height/2+zoom.y)}
            overlay.allowsHitTesting(false)
            if let interaction { interaction.environment(\.viewportTouch, touch) }
            if let caption {
              VStack {
                Spacer()
                caption.environment(\.captionMinimumBottom, visible && showsControls ? (size.width < 600 || textSize.isAccessibilitySize ? 118 : 70) : 0)
              }.padding(.bottom, insets.bottom)
            }
          }
        }.frame(width: size.width, height: size.height).clipped().contentShape(Rectangle())
          .simultaneousGesture(
            MagnifyGesture().onChanged { v in
              guard showsControls, !system, !clock.picture.inPictureInPicture else { return }
              if initialZoom == nil { initialZoom = zoom }
              touch.pinching = true
              touch.horizontalSeek = nil
              zoom = (initialZoom ?? zoom).magnified(
                v.magnification,
                anchor: CGPoint(x: v.startAnchor.x, y: v.startAnchor.y), size: size,
                shrinks: shrinks)
              if !visible { visible = true }
            }.onEnded { _ in
              if touch.pinching {
                touch.ignorePanBefore = ProcessInfo.processInfo.systemUptime + 0.2
              }
              initialZoom = nil
              touch.pinching = false
              wake()
            }, including: system || !showsControls ? .subviews : .all
          )
          .simultaneousGesture(
            TapGesture(count:2).exclusively(before:TapGesture()).onEnded{value in
              guard case .second=value,showsControls,!system,!clock.picture.inPictureInPicture,touch.acceptsPan else{return}
              DispatchQueue.main.async{
                guard ProcessInfo.processInfo.systemUptime-touch.lastBulletTap>0.08 else{return}
                // A tap on the picture first puts an open panel away.
                if panel != nil { closePanel(); return }
                visible.toggle();wake()
              }
            },including:system || !showsControls ? .subviews:.all)
        if showsControls && !clock.picture.inPictureInPicture {
          if system {
            VStack {
              HStack {
                Spacer()
                Button {
                  system = false
                  visible = true
                  wake()
                } label: {
                  Label("应用控件", systemImage: "rectangle.and.hand.point.up.left")
                    .font(.caption).padding(6).background(.black.opacity(0.65), in: Capsule())
                }.foregroundStyle(.white)
                Spacer()
              }
              Spacer()
            }.padding(.top, 4)
          } else if fullscreen && slots.close != nil {
            // Pages that fill the new chrome's slots (the theater); the offline file player
            // keeps its own navigation bar and the classic bars.
            fullscreenControls(size: size, safe: safe, insets: insets,
              picture: shownWidth(chosen, frame: frame, source: clock.pictureSize))
          } else {
            appControls(width: safe.width).padding(insets)
          }
        }
        if scrollVolume && !detached {
          // Marks the area only; its recognizer is on the window (see PointerVolume).
          PointerVolume(player: player) { level in
            routeVolume=false;volumeHint = level; volumeSequence &+= 1
          }.allowsHitTesting(false).accessibilityHidden(true)
        }
        if let volumeHint {
          if fullscreen {
            VStack {
              PlayerLevelHUD(symbol: PlayerLevelPill.volumeSymbol(Double(volumeHint) / 100), percent: volumeHint)
              Spacer(minLength: 0)
            }.padding(.top, 26).accessibilityHidden(true)
          } else {
            PlayerLevelPill(
              symbol: PlayerLevelPill.volumeSymbol(Double(volumeHint) / 100), percent: volumeHint
            ).accessibilityHidden(true)
          }
        }
      }.frame(width: size.width, height: size.height)
    }
    .preference(key: PlayerControlsVisibleKey.self, value: visible && showsControls && !system)
    .onReceive(AVAudioSession.sharedInstance().publisher(for:\.outputVolume).removeDuplicates().dropFirst()){level in
      guard !detached,level.isFinite else{return}
      routeVolume=true;volumeHint=Int((min(1,max(0,level))*100).rounded());volumeSequence &+= 1
    }.task(id: volumeSequence) {
      guard volumeHint != nil else { return }
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      volumeHint = nil
    }.onAppear {
      clock.attach(player)
      touch.reveal = {
        visible = true
        pulse &+= 1
      }
      wake()
    }
    .background { if let native = player.nativePlayer { VideoSceneMarker(player: native) } }
    .background { if let mpv = player as? MPVPlayer, let upscale { MPVUpscaleBinding(player: mpv, session: upscale) } }
    .alert("画中画", isPresented: Binding(get: { pipError != nil }, set: { if !$0 { pipError = nil } })) {
      Button("好") {}
    } message: { Text(pipError ?? "") }
  }
  var body: some View {
    stage
    .onReceive(NotificationCenter.default.publisher(for: .piliStartPictureInPicture)) { n in
      if (n.object as AnyObject?) === player { resetZoom() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .piliMPVPiPError)) { n in
      if (n.object as AnyObject?) === player { pipError = "画中画启动失败，请稍后重试" }
    }
    .onChange(of: ObjectIdentifier(player)) { _, _ in
      clock.attach(player)
      wake()
    }
    .onChange(of: clock.item) { _, _ in
      resetZoom()
      visible = true
      wake()
    }
    .onChange(of: showsControls) { _, v in
      if !v { system = false }
      visible = v
      wake()
    }
    .onChange(of: shrinks) { _, enabled in if !enabled && zoom.scale < 1 { resetZoom() } }
    .onChange(of: clock.playing) { _, _ in wake() }
    .onChange(of: controlsFocused) { _, _ in wake() }
    .onChange(of: longer) { _, _ in wake() }
    .onChange(of: voiceOver) { _, on in
      if on { visible = true }
      wake()
    }
    .onDisappear {
      clock.close()
      touch.pinching = false
      touch.horizontalSeek = nil
      touch.reveal = nil
    }
    // The official client's auto-hide: 3 s after the controls come up, and only while playing —
    // paused, they stay until tapped away. Resuming restarts the timer (clock.playing above).
    .task(id: pulse) {
      guard visible, !system, showsControls, !editing, panel == nil else { return }
      do { try await Task.sleep(for: .seconds(longer ? 30 : 3)) } catch { return }
      if ProcessInfo.processInfo.systemUptime < holdUntil {
        pulse &+= 1
        return
      }
      guard !Task.isCancelled, clock.playing, panel == nil, !editing else { return }
      let touching: Bool = touch.pinching || touch.horizontalSeek != nil
      let reading: Bool = controlsFocused || voiceOver
      if !touching && !reading { visible = false }
    }
    // A seek by sliding over the picture puts the controls away when it ends, as the official
    // client does.
    .onChange(of: touch.horizontalSeek == nil) { _, ended in
      if ended, visible, !voiceOver, panel == nil { visible = false }
    }
    // Back from fullscreen: the inline controls come up for their 3 s, as on entering it.
    .onChange(of: detached) { _, covered in
      if !covered {
        visible = true
        wake()
      }
    }
    .onChange(of: visible) { _, shown in
      guard fullscreen else { return }
      if shown {
        lockHint = false
      } else {
        panel = nil
        // As in the reference player: the lock stays where play was for a few seconds.
        if showsControls, slots.lock != nil {
          lockHint = true
          lockPulse &+= 1
        }
      }
    }
    .task(id: lockPulse) {
      guard lockHint else { return }
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      lockHint = false
    }
  }
  // MARK: Fullscreen chrome

  /// The fullscreen layout (FullscreenChrome.swift has the parts): status line and header on a
  /// light top shade; progress, then play / next and the word buttons on a bottom shade that
  /// deepens and blurs when a panel takes the buttons' place.
  /// As the reference player: the chrome lines up with the picture's sides when the picture is
  /// narrower than the screen (a 16:9 video on a tall phone), instead of the screen's edges.
  /// Pictures much narrower than the screen (portrait video in landscape) keep the full width.
  static func pictureInset(size: CGSize, picture: CGFloat) -> CGFloat {
    guard size.width > 0, picture.isFinite, picture >= size.width * 0.7 else { return 0 }
    return max(0, (size.width - picture) / 2)
  }
  /// The width the picture is drawn at. Fitting is done by the video layer inside a full-size
  /// frame, so the frame alone does not say where the picture's sides are.
  private func shownWidth(_ fit: PictureFit, frame: CGSize, source: CGSize) -> CGFloat {
    guard fit == .fit, source.width > 0, source.height > 0, frame.height > 0 else {
      return frame.width * zoom.scale
    }
    return min(frame.width, frame.height * source.width / source.height) * zoom.scale
  }
  /// `size` is the whole screen (the shades cover it); `safe` and `insets` are the safe area the
  /// controls keep to.
  @ViewBuilder private func fullscreenControls(size: CGSize, safe: CGSize, insets: EdgeInsets, picture: CGFloat) -> some View {
    let open = slots.panels.first { $0.id == panel }
    let side = (safe.width < safe.height ? 16 : 0) + Self.pictureInset(size: safe, picture: picture)
    let edges = EdgeInsets(top: insets.top, leading: insets.leading + side, bottom: insets.bottom,
      trailing: insets.trailing + side)
    ZStack {
      if visible {
        fullscreenShade(open: open != nil, height: size.height).transition(.opacity)
        if open != nil {
          Color.clear.contentShape(Rectangle()).onTapGesture { closePanel() }.accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 0) {
          PlayerStatusRow().padding(.top, 6)
          fullscreenHeader
          if let info = slots.info {
            info.padding(.top, 2).transition(.opacity.combined(with: .offset(y: -8)))
          }
          Spacer(minLength: 0)
          if !live, clock.duration > 0 {
            FullscreenSeekBar(
              clock: clock, readout: clock.readout, seek: jump, editing: edit,
              external: touch.horizontalSeek, marks: marks, scrub: $scrub)
          }
          ZStack(alignment: .topLeading) {
            if let open {
              open.content
                .environment(\.playerPanelDismiss, { closePanel() })
                .padding(.top, 6).padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
              fullscreenButtons.transition(.opacity)
            }
          }
        }
        // Landscape gets its margins from the safe area; a portrait screen has none at the sides.
        .padding(edges)
        .transition(.opacity)
        if previews, let scrub, let timeline {
          VStack {
            Spacer(minLength: 0)
            HStack {
              Spacer(minLength: 0)
              ShotPreview(state: timeline, seconds: scrub, limit: CGSize(width: 228, height: 128), corner: 12, framed: true)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            }
            .padding(.trailing, insets.trailing + (size.width < size.height ? 16 : 24)).padding(.bottom, insets.bottom + 124)
          }
          .allowsHitTesting(false).transition(.opacity)
        }
      } else if lockHint, let lock = slots.lock {
        VStack {
          Spacer(minLength: 0)
          HStack {
            Button { lock() } label: {
              Image(systemName: "lock.open").font(.system(size: 22, weight: .medium))
                .frame(width: 44, height: 48, alignment: .leading).contentShape(Rectangle())
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .accessibilityLabel("锁定播放控件")
            Spacer(minLength: 0)
          }
        }
        .padding(edges)
        .transition(.opacity)
      }
      // Paused with the controls put away: the reference player's play mark in a glass bubble.
      if !visible, panel == nil, clock.ready, !clock.playing {
        PlayerPausedBubble { playPause(); wake() }
          .transition(.opacity.combined(with: .scale(scale: 1.15)))
      }
    }
    .foregroundStyle(.white).buttonStyle(PlayerPressStyle())
    .environment(\.colorScheme, .dark)
    .animation(PlayerChromeMotion.fade, value: visible)
    .animation(PlayerChromeMotion.fade, value: lockHint)
    .animation(PlayerChromeMotion.panel, value: panel)
    .animation(PlayerChromeMotion.fade, value: scrub == nil)
    .accessibilityElement(children: .contain).accessibilityFocused($controlsFocused)
  }
  private func fullscreenShade(open: Bool, height: CGFloat) -> some View {
    VStack(spacing: 0) {
      LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
        .frame(height: 120)
      Spacer(minLength: 0)
      ZStack {
        if open {
          // Under a panel the picture is frosted as well as darkened.
          Rectangle().fill(.ultraThinMaterial)
            .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
        }
        LinearGradient(colors: [.black.opacity(0), .black.opacity(open ? 0.78 : 0.55)], startPoint: .top, endPoint: .bottom)
      }
      .frame(height: open ? height * 0.7 : 150)
    }
    .ignoresSafeArea().allowsHitTesting(false)
  }
  private var fullscreenHeader: some View {
    HStack(spacing: 0) {
      if let close = slots.close {
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 19, weight: .medium))
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }.accessibilityLabel("退出全屏")
      }
      if let title = slots.title {
        Text(title).font(.system(size: 17, weight: .medium)).lineLimit(1)
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          // 12 pt from the close glyph to the title, as in the reference header.
          .padding(.leading, -3).layoutPriority(-1)
      }
      Spacer(minLength: 16)
      if let tools = slots.tools { tools.simultaneousGesture(TapGesture().onEnded { holdChrome() }) }
    }
    .frame(height: 44)
    // The first and last glyphs line up with the bars' edges, not their 44 pt cells.
    .padding(.horizontal, -11)
  }
  private var fullscreenButtons: some View {
    HStack(spacing: 0) {
      Button { playPause(); wake() } label: {
        Image(systemName: clock.playing ? "pause.fill" : "play.fill")
          .font(.system(size: 27, weight: .medium))
          .frame(width: 44, height: 48, alignment: .leading).contentShape(Rectangle())
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .contentTransition(.symbolEffect(.replace))
      }.accessibilityLabel(clock.playing ? "暂停" : "播放").disabled(!clock.ready)
      if let next = slots.next {
        Button { next(); wake() } label: {
          Image(systemName: "forward.end.fill")
            .font(.system(size: 21, weight: .medium))
            .frame(width: 44, height: 48, alignment: .leading).contentShape(Rectangle())
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }.accessibilityLabel("下一集").padding(.leading, 22)
      }
      if live {
        Text("直播").font(.system(size: 15, weight: .semibold)).padding(.leading, 12)
      }
      Spacer(minLength: 8)
      HStack(spacing: 18) {
        if let upscale { UpscaleButton(session: upscale) }
        if abs(zoom.scale - 1) > 0.005 {
          Button {
            withAnimation(.easeOut(duration: 0.22)) { resetZoom() }
            wake()
          } label: { PlayerWordGlyph(text: "还原") }
            .accessibilityLabel("还原画面").transition(.opacity)
        }
        ForEach(slots.panels) { p in
          Button {
            TouchFeedback.light()
            withAnimation(PlayerChromeMotion.panel) { panel = p.id }
            wake()
          } label: { PlayerWordGlyph(text: p.title) }
        }
        if let menus = slots.menus { menus.simultaneousGesture(TapGesture().onEnded { holdChrome() }) }
      }
      .padding(.trailing, -10)
    }
    .frame(height: 48)
  }
  private func holdChrome() {
    holdUntil = ProcessInfo.processInfo.systemUptime + 12
    wake()
  }
  private func closePanel() {
    withAnimation(PlayerChromeMotion.panel) { panel = nil }
    wake()
  }
  /// The original client's player chrome: a header (back/title left, tools right) and a bottom
  /// bar (progress, then play/time left and menus/fullscreen right), each on a 75 % black
  /// gradient that slides in from its own edge. Fullscreen adds the action row under the header
  /// and edge buttons at mid-height.
  @ViewBuilder private func appControls(width: CGFloat) -> some View {
    ZStack {
      if visible {
        VStack(spacing: 0) {
          topBar(width: width)
          if fullscreen, let under = slots.underHeader {
            HStack(spacing: 0) {
              Spacer(minLength: 0)
              under
            }
            .padding(.trailing, 6)
          }
          Spacer(minLength: 0)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          bottomBar(width: width)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        if previews, let scrub, let timeline {
          // The frame being scrubbed to, framed on the right above the bar as in fullscreen.
          VStack {
            Spacer(minLength: 0)
            HStack {
              Spacer(minLength: 0)
              ShotPreview(state: timeline, seconds: scrub, limit: CGSize(width: 160, height: 90), framed: true)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
            .padding(.trailing, 12).padding(.bottom, 78)
          }
          .allowsHitTesting(false).transition(.opacity)
        }
        if fullscreen && (slots.edgeLeading != nil || slots.edgeTrailing != nil) {
          HStack(spacing: 0) {
            slots.edgeLeading
            Spacer(minLength: 0)
            slots.edgeTrailing
          }
          .padding(.horizontal, 14)
          .offset(y: -16)
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      } else if !live, clock.duration > 0,
        (ViewportProgress(rawValue: progress) ?? .always).visible(
          fullscreen: fullscreen, controls: visible,
          seeking: touch.horizontalSeek != nil || editing)
      {
        VStack {
          Spacer()
          ViewportSeekBar(
            clock: clock, readout: clock.readout, seek: jump, editing: edit, compact: true, external: touch.horizontalSeek,
            marks: marks,timeline:timeline)
        }
        .transition(.opacity)
      }
    }
    .foregroundStyle(.white).buttonStyle(PlayerPressStyle())
    .environment(\.colorScheme, .dark)
    .animation(.smooth(duration: 0.28), value: visible)
    .accessibilityElement(children: .contain).accessibilityFocused($controlsFocused)
  }
  private func topBar(width: CGFloat) -> some View {
    HStack(spacing: 0) {
      if let lead = slots.headerLeading {
        lead
      } else if !fullscreen {
        // Inline, the page draws back and home over this corner (they exist before the player
        // is ready), hiding with these controls.
        Color.clear.frame(width: 80, height: 40)
      }
      if let title = slots.title, fullscreen || width >= 600 {
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 16, weight: .medium)).lineLimit(1)
          if let sub = slots.subtitle {
            Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
          }
        }
        .padding(.leading, 4).padding(.trailing, 10)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .layoutPriority(-1)
      }
      Spacer(minLength: 8)
      PlayerHeaderStatus(fullscreen: fullscreen)
      if let trailing = slots.headerTrailing { trailing }
    }
    .frame(height: 40)
    .padding(.horizontal, fullscreen ? 10 : 4)
    .padding(.top, fullscreen ? 8 : 4)
    .padding(.bottom, 22)
    .background {
      LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea(edges: .top).allowsHitTesting(false)
    }
  }
  /// The inline bottom bar in the fullscreen chrome's style: the time, a thick white bar with no
  /// thumb and the length on one row, then play and the menus under it.
  private func bottomBar(width: CGFloat) -> some View {
    VStack(spacing: 0) {
      if !live, clock.duration > 0 {
        FullscreenSeekBar(
          clock: clock, readout: clock.readout, seek: jump, editing: edit,
          external: touch.horizontalSeek, marks: marks, scrub: $scrub, compact: true)
          .padding(.horizontal, 12)
          // Its touch band ends where the buttons begin, so it never steals their taps.
          .padding(.bottom, -4)
      }
      HStack(spacing: 0) {
        playControl
        if live {
          Text("直播").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
        }
        if let lead = slots.bottomLeading { lead }
        Spacer(minLength: 4)
        accessoryControls(wide: fullscreen || width >= 500)
      }
      .frame(height: 40)
    }
    .padding(.horizontal, fullscreen ? 10 : 2)
    .padding(.top, 30).padding(.bottom, fullscreen ? 6 : 0)
    .background(alignment: .bottom) {
      LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea(edges: .bottom).allowsHitTesting(false)
    }
  }
  private var playControl: some View {
    Button { playPause(); wake() } label: {
      PlayerGlyph(symbol: clock.playing ? "pause.fill" : "play.fill", size: 21)
    }.accessibilityLabel(clock.playing ? "暂停" : "播放").disabled(!clock.ready)
  }
  /// The original's order on the right: super resolution, episodes, picture fit (wide only),
  /// subtitles / speed / quality from the page, then fullscreen.
  @ViewBuilder private func accessoryControls(wide: Bool) -> some View {
    if let upscale { UpscaleButton(session: upscale) }
    if let episode = slots.bottomEpisode { episode }
    if wide { PlayerFitMenu(player: player, session: clock.picture) }
    if let trailing = slots.bottomTrailing { trailing }
    if wide, let extra = slots.bottomWide { extra }
    if abs(zoom.scale - 1) > 0.005 {
      Button {
        withAnimation(.easeOut(duration: 0.22)) { resetZoom() }
        wake()
      } label: {
        PlayerGlyph(symbol: "arrow.up.left.and.down.right.magnifyingglass")
      }.accessibilityLabel("还原画面").accessibilityValue(String(format: "%.2f 倍", zoom.scale))
      .transition(.scale.combined(with: .opacity))
    }
    if let expand {
      Button {
        expand()
      } label: {
        PlayerGlyph(
          symbol: fullscreen
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
          size: 18)
      }.accessibilityLabel(fullscreen ? "退出全屏" : "全屏")
      .contextMenu {
        Button("系统播放控件", systemImage: "rectangle.and.hand.point.up.left") {
          resetZoom()
          system = true
        }.disabled(!player.supportsSystemVideo)
      }
    }
  }
  private func wake() { pulse &+= 1 }
  private func edit(_ value: Bool) {
    let ended = editing && !value
    editing = value
    // As the official client: letting go of the progress bar puts the controls away.
    if ended && !voiceOver && panel == nil { visible = false }
    wake()
  }
  private func jump(_ seconds: Double) {
    guard !live, clock.ready, clock.duration > 0, seconds.isFinite else { return }
    if let seek {
      seek(seconds)
    } else {
      PictureSession.shared(player).seek(player, to: min(clock.duration, max(0, seconds)))
    }
  }
  private func playPause() {
    if let toggle {
      toggle()
      return
    }
    if player.timeControlStatus == .paused { player.play() } else { player.pause() }
  }
  private func resetZoom() {
    zoom = ViewportZoom()
    initialZoom = nil
    touch.pinching = false
  }
}
