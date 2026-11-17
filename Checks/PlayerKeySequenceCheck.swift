import Foundation

@main enum PlayerKeyCheck {
  static func main() throws {
    let vod = PlayerKeyScope(
      live: false, social: true, relation: true, send: true, full: true, capture: true, step: true,
      ready: true, canPlay: true, locked: false)
    let live = PlayerKeyScope(
      live: true, social: false, relation: false, send: true, full: true, capture: true,
      step: false, ready: true, canPlay: true, locked: false)
    let offline = PlayerKeyScope(
      live: false, social: false, relation: false, send: true, full: true, capture: true,
      step: true, ready: true, canPlay: true, locked: false)
    let course = PlayerKeyScope(
      live: false, social: false, relation: false, send: true, full: false, capture: false,
      step: true, ready: true, canPlay: true, locked: false)
    let locked = PlayerKeyScope(
      live: false, social: true, relation: true, send: true, full: true, capture: true, step: true,
      ready: true, canPlay: true, locked: true)
    var k = PlayerKeySequence()
    func eq(_ got: [PlayerKeyEffect], _ expected: [PlayerKeyEffect]) {
      precondition(got == expected, "\(got) != \(expected)")
    }
    eq(k.down(.q, at: 0, scope: vod), [])
    eq(k.up(.q, at: 199, playing: true), [.like])
    eq(k.down(.r, at: 201, scope: vod), [])
    eq(k.up(.r, at: 299, playing: true), [])
    eq(k.down(.q, at: 1000, scope: vod), [])
    eq(k.pulse(1199, playing: true), [])
    eq(k.pulse(1200, playing: true), [.armTriple])
    eq(k.up(.q, at: 2399, playing: true), [])
    for key: PlayerKey in [.q, .r] {
      eq(k.down(key, at: 3000, scope: vod), [])
      eq(k.down(key, at: 3060, scope: vod), [])
      eq(k.pulse(3200, playing: true), [.armTriple])
      eq(k.pulse(4399, playing: true), [])
      eq(k.pulse(4400, playing: true), [.triple])
      eq(k.pulse(5000, playing: true), [])
      eq(k.up(key, at: 6000, playing: true), [])
    }
    eq(k.down(.q, at: 10, scope: vod), [])
    eq(k.pulse(210, playing: true), [.armTriple])
    eq(k.down(.w, at: 1000, scope: vod), [.coin])
    eq(k.up(.q, at: 1700, playing: true), [])
    eq(k.down(.q, at: 10, scope: vod), [])
    eq(k.cancel(), [])
    eq(k.pulse(1500, playing: true), [])
    eq(k.up(.q, at: 1700, playing: true), [])
    eq(k.down(.left, at: 0, scope: vod), [])
    eq(k.up(.left, at: 140, playing: false), [.seekBack(1)])
    eq(k.down(.left, at: 0, scope: vod), [])
    eq(k.pulse(200, playing: true), [.previewBack(1)])
    eq(k.pulse(600, playing: true), [.previewBack(3)])
    eq(k.up(.left, at: 690, playing: true), [.seekBack(3)])
    eq(k.down(.right, at: 0, scope: vod), [])
    eq(k.up(.right, at: 199, playing: false), [.seekForward])
    eq(k.down(.right, at: 0, scope: vod), [])
    eq(k.pulse(200, playing: true), [.boost])
    eq(k.up(.right, at: 1100, playing: true), [.restore])
    eq(k.down(.right, at: 0, scope: vod), [])
    eq(k.pulse(220, playing: false), [])
    eq(k.up(.right, at: 240, playing: false), [.seekForward])
    eq(k.down(.up, at: 0, scope: vod), [.volume(1)])
    eq(k.pulse(149, playing: true), [])
    eq(k.pulse(150, playing: true), [.volume(1)])
    eq(k.pulse(300, playing: true), [.volume(1)])
    eq(k.up(.up, at: 310, playing: true), [])
    eq(k.pulse(1000, playing: true), [])
    for (key, effect): (PlayerKey, PlayerKeyEffect) in [
      (.w, .coin), (.e, .favorite), (.t, .later), (.v, .later), (.g, .relation), (.enter, .enter),
      (.f, .fullscreen), (.m, .mute), (.s, .capture), (.d, .bullets), (.space, .toggle),
      (.l, .lock), (.previous, .previous), (.next, .next), (.slower, .changeSpeed(-1)),
      (.faster, .changeSpeed(1)),
    ] {
      eq(k.down(key, at: 0, scope: vod), [effect])
      eq(k.up(key, at: 2, playing: true), [])
    }
    eq(k.down(.one, at: 0, scope: vod), [])
    eq(k.down(.one, at: 0, scope: vod, shift: true), [.setSpeed(1)])
    eq(k.down(.two, at: 0, scope: vod, shift: true), [.setSpeed(2)])
    for media in [live, offline, course] {
      for key: PlayerKey in [.w, .e, .t, .v, .g] {
        precondition(!media.supports(key, shift: false))
      }
    }
    for key: PlayerKey in [.q, .r] {
      eq(k.down(key, at: 0, scope: live), [.refresh])
      eq(k.up(key, at: 2000, playing: true), [])
    }
    precondition(
      !live.supports(.right, shift: false) && !live.supports(.faster, shift: false)
        && !course.supports(.s, shift: false))
    for key: PlayerKey in [.q, .w, .t, .m, .space, .right, .enter] {
      precondition(!locked.supports(key, shift: false))
    }
    precondition(locked.supports(.f, shift: false) && locked.supports(.l, shift: false))
    precondition(
      PlayerTouchZone.doubleTap(24.999, width: 100) == .back
        && PlayerTouchZone.doubleTap(25, width: 100) == .center
        && PlayerTouchZone.doubleTap(74.999, width: 100) == .center
        && PlayerTouchZone.doubleTap(75, width: 100) == .forward)
    var glyph = BulletPauseClock<String>()
    glyph.hold("first", start: 1, duration: 4, sample: 2, at: 2)
    precondition(glyph.visible(at: 100).first?.1 == 2)
    glyph.release(at: 100)
    precondition(glyph.visible(at: 101).first?.1 == 3)
    glyph.hold("second", start: 90, duration: 20, sample: 101, at: 101)
    precondition(
      glyph.visible(at: 102).count == 2 && glyph.visible(at: 103).map { $0.0 } == ["second"])
    glyph.release(at: 105)
    precondition(glyph.visible(at: 107).first?.1 == 103)
    glyph.hold("second", start: 90, duration: 20, sample: 103, at: 107)
    precondition(glyph.visible(at: 200).map { $0.1 } == [103])
    glyph.release(at: 200)
    precondition(glyph.visible(at: 207).isEmpty)
    let center = CGPoint(x: 0.5, y: 0.5)
    let size = CGSize(width: 360, height: 640)
    let zoom = ViewportZoom()
    precondition(
      zoom.magnified(0.4, anchor: center, size: size, shrinks: true).scale == 0.75
        && zoom.magnified(0.4, anchor: center, size: size, shrinks: false).scale == 1
        && zoom.magnified(3, anchor: center, size: size, shrinks: true).scale == 2)
    precondition(
      PlayerSlide.axis(dx: 3, dy: 1, x: 30, width: 120, levels: true, screen: true) == nil)
    precondition(
      PlayerSlide.axis(dx: 1, dy: 4, x: 39, width: 120, levels: true, screen: true) == .brightness)
    precondition(
      PlayerSlide.axis(dx: 1, dy: 4, x: 40, width: 120, levels: true, screen: true) == .fullscreen)
    precondition(
      PlayerSlide.axis(dx: 1, dy: 4, x: 80, width: 120, levels: true, screen: true) == .volume)
    precondition(
      FullscreenMode.swipe(fullscreen: false, reverse: true, x: 50, width: 100, dx: 0, dy: 3))
    precondition(
      !ViewportProgress.fullOnly.visible(fullscreen: false, controls: false, seeking: false)
        && ViewportProgress.fullOnly.visible(fullscreen: true, controls: false, seeking: false))
    let bv = ArchiveNumber.bv(123)!
    let ugc = EngagementItem(bvid: bv, aid: 123, episode: nil, copyright: 2)
    let ep = EngagementItem(bvid: bv, aid: 123, episode: 777, copyright: 1)
    let like = try PlaybackSocialRequest.like(ugc, on: false)
    let co = try PlaybackSocialRequest.coin(ugc, amount: 1, already: 0, withLike: true)
    let tr = try PlaybackSocialRequest.triple(ep)
    let ut = try PlaybackSocialRequest.triple(ugc)
    precondition(
      like.fields == ["bvid": bv, "like": "2"]
        && co.fields == ["aid": "123", "multiply": "1", "select_like": "1"]
        && tr.path == "/pgc/season/episode/like/triple" && tr.fields == ["ep_id": "777"]
        && ut.fields == ["aid": "123"])
    do {
      _ = try PlaybackSocialRequest.coin(ugc, amount: 2, already: 0, withLike: true)
      preconditionFailure()
    } catch {}
    let add = try PlaybackSocialRequest.later(ugc, removing: false)
    let del = try PlaybackSocialRequest.later(ugc, removing: true)
    precondition(
      add.fields == ["bvid": bv] && del.fields == ["resources": "123"] && add.path != del.path)
    do {
      _ = try PlaybackSocialRequest.later(
        .init(bvid: bv, aid: 999, episode: nil, copyright: 1), removing: true)
      preconditionFailure()
    } catch {}
    print(
      "Real key sequence: 199/200/1399/1400 ms Q/R, cancellation/repeat, volume 150 ms, left/right 200 ms, paused release, media and lock scopes, 1/4–3/4 touch thresholds and archive/episode write shapes passed; no network write"
    )
  }
}
