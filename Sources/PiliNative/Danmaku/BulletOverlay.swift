import AVFoundation
import SwiftUI
import UIKit

struct BulletOverlay: View {
  let items: [Bullet]
  let time: Double
  @AppStorage("dm.opacity") private var opacity = 1.0
  @AppStorage("dm.area") private var displayArea = 0.5
  @AppStorage("dm.blocked") private var blocked = ""
  @AppStorage(DanmakuStyle.key) private var storedStyle = Data()
  @ObservedObject private var cloud = AccountBulletRules.shared
  @State private var layout: BulletScene?
  private struct LayoutKey: Equatable {
    let size: CGSize
    let revision: UUID
    let area: Double, inspect: Bool
    let blocked: String
    let point: Double, scale: Double
    let style: Data
    let cloudRevision: UUID
  }
  let revision: UUID
  var clock: (any PlaybackEngine)? = nil
  var inspector: BulletInspector? = nil
  @Environment(\.scenePhase) private var scene
  @Environment(\.displayScale) private var displayScale
  /// 0 = let the system pick the frame rate.
  private let fps = 0
  var fullscreen = false
  @AppStorage("dm.fontSize") var normal = 15.0
  @AppStorage("dm.fullFontSize") var full = 18.0
  private var point: Double { fullscreen ? full : normal }
  nonisolated static func row<T>(_ pick:BulletPick,in entries:[T],bullet:(T)->Bullet)->Int?{
    if entries.indices.contains(pick.index),bullet(entries[pick.index])==pick.bullet{return pick.index}
    var lo=0,hi=entries.count
    while lo<hi{let m=lo+(hi-lo)/2;if bullet(entries[m]).time<pick.bullet.time{lo=m+1}else{hi=m}}
    while lo<entries.count,bullet(entries[lo]).time==pick.bullet.time{
      if bullet(entries[lo])==pick.bullet{return lo};lo+=1
    }
    return nil
  }
  var body: some View {
    GeometryReader { geo in
      BulletLayerSurface(scene: opacity > 0 && scene == .active ? layout : nil, player: clock,
        inspector: inspector, fps: fps)
      .opacity(opacity).task(
        id: LayoutKey(
          size: geo.size, revision: revision, area: displayArea, inspect: opacity > 0, blocked: blocked, point: point, scale: displayScale,
          style: storedStyle, cloudRevision: cloud.revision)
      ) {
        guard opacity > 0, !items.isEmpty else {
          layout = nil
          inspector?.locate = nil; inspector?.snapshot = nil; inspector?.clearTimeline()
          return
        }
        let config = DanmakuStyle.decode(storedStyle)
        let uid = try? await AccountJar.shared.current()?.id
        let rules = cloud.rows(uid)
        let owner = uid.map(DanmakuStyle.senderHash)
        guard !Task.isCancelled else { return }
        let weights: [UIFont.Weight] = [
          .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
        ]
        let items = self.items, keywords = blocked, point = self.point, scale = displayScale
        let size = geo.size, area = displayArea
        let work = Task.detached(priority: .userInitiated) {
          let font = UIFont.systemFont(ofSize: point, weight: BulletRasterCache.weight(config.fontWeight))
          let badge = UIFont.systemFont(ofSize: point * 0.6, weight: BulletRasterCache.weight(config.fontWeight))
          let plan = try BulletLayoutPlan.prepare(items, style: config, keywords: keywords, own: owner,
            cloud: CloudBulletMatcher(rules), size: size, area: area, point: point) { text, isBadge in
              (text as NSString).size(withAttributes: [.font: isBadge ? badge : font]).width
            }
          return plan
        }
        let plan: BulletLayoutPlan
        do { plan = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch { return }
        guard !Task.isCancelled else { return }
        layout = BulletScene(plan: plan, style: config, point: point, scale: scale)
        if opacity <= 0 { inspector?.locate = nil; inspector?.snapshot=nil;inspector?.clearTimeline() }
        if let inspector, opacity > 0 {
          let clock = self.clock
          let fallback = time
          let pt = point
          let step = point * config.lineHeight
          let size = geo.size
          let bars = plan.rows, fx = plan.special
          inspector.playhead = { clock?.currentTime().seconds ?? fallback }
          func rowHit(_ i:Int,at t:Double,point:CGPoint?) -> BulletPick? {
            let p=bars[i]
            guard let rect=BulletTrackFrame.rect(mode:p.mode,lane:p.lane,width:p.width,point:pt,step:step,elapsed:t-p.bullet.time,duration:p.duration,size:size),
                  CGRect(origin:.zero,size:size).intersects(rect), point.map({rect.insetBy(dx:-1,dy:-1).contains($0)}) ?? true else{return nil}
            return BulletPick(index:i,sample:t,duration:p.duration,bullet:p.bullet,rect:rect,text:p.bullet.text)
          }
          func fxHit(_ i:Int,at t:Double,point:CGPoint?) -> BulletPick?{
            let b=fx[i];guard let sp=b.special else{return nil}
            let dt=t-b.time;guard dt>=0,dt<sp.duration else{return nil}
            let frame=sp.frame(dt),tilt=cos(sp.tilt * .pi / 180)
            guard frame.opacity>0.01,abs(tilt)>0.001 else{return nil}
            let transform=CGAffineTransform(translationX:frame.x*size.width,y:frame.y*size.height).rotated(by:sp.angle * .pi/180).scaledBy(x:tilt,y:1)
            let font=UIFont.systemFont(ofSize:min(8192,max(1,b.fontSize)),weight:weights[min(8,max(0,config.fontWeight-1))])
            let rect=CGRect(origin:.zero,size:(sp.text as NSString).size(withAttributes:[.font:font]))
            guard point.map({rect.contains($0.applying(transform.inverted()))}) ?? true else{return nil}
            return BulletPick(index:i,sample:t,duration:sp.duration,bullet:b,rect:rect.applying(transform),text:sp.text)
          }
          func shifted(_ p:BulletPick,at t:Double,point:CGPoint?)->BulletPick?{
            if p.bullet.special != nil { return Self.row(p,in:fx,bullet:{$0}).flatMap{fxHit($0,at:t,point:point)} }
            return Self.row(p,in:bars,bullet:{$0.bullet}).flatMap{rowHit($0,at:t,point:point)}
          }
          inspector.snapshot = { [weak inspector] in
            let now=clock?.currentTime().seconds ?? fallback
            guard now.isFinite else{return []}
            let extra=inspector?.pauseClock.visible(at:now) ?? []
            var fixed=[Bullet](),scrolling=[Bullet](),advanced=[Bullet]()
            func add(_ b:Bullet){if b.special != nil{advanced.append(b)}else if b.mode==4 || b.mode==5{fixed.append(b)}else{scrolling.append(b)}}
            let extent=CGRect(origin:.zero,size:size)
            for i in plan.regular(at: now) {
              let p=bars[i];guard !extra.contains(where:{$0.0.bullet==p.bullet}),let r=BulletTrackFrame.rect(mode:p.mode,lane:p.lane,width:p.width,point:pt,step:step,elapsed:now-p.bullet.time,duration:p.duration,size:size),extent.intersects(r) else{continue}
              add(p.bullet)
            }
            for i in plan.effects(at: now) {
              let b=fx[i];if !extra.contains(where:{$0.0.bullet==b}),let sp=b.special,now-b.time<sp.duration,sp.frame(now-b.time).opacity>0 {add(b)}
            }
            for (p,t) in extra{if let current=shifted(p,at:t,point:nil),extent.intersects(current.rect){add(current.bullet)}}
            return fixed+scrolling+advanced
          }
          inspector.locate = { [weak inspector] point in
            let now=clock?.currentTime().seconds ?? fallback;guard now.isFinite else{return nil}
            let extra=inspector?.pauseClock.visible(at:now) ?? []
            for (p,t) in extra.reversed(){if let hit=shifted(p,at:t,point:point){return hit}}
            for i in plan.regular(at: now).reversed() {
              if !extra.contains(where:{$0.0.bullet==bars[i].bullet}),let hit=rowHit(i,at:now,point:point){return hit}
            }
            for i in plan.effects(at: now).reversed() {
              if !extra.contains(where:{$0.0.bullet==fx[i]}),let hit=fxHit(i,at:now,point:point){return hit}
            }
            return nil
          }
        }
      }
    }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    .onReceive(NotificationCenter.default.publisher(for: clock?.engineKind == .mpv ? .piliEngineTimeJumped : AVPlayerItem.timeJumpedNotification)){ note in
      if let item=note.object as AnyObject?,item===clock?.playbackItem{inspector?.clearTimeline()}
    }.onDisappear {
      inspector?.locate = nil
      inspector?.snapshot=nil
      inspector?.clearTimeline();inspector?.playhead=nil
    }
  }
}
