import SwiftUI

struct SongHeatGraph: View {
  let points: [MusicRecord.Point]
  @State private var index: Int?
  private func day(_ p: MusicRecord.Point) -> String { Date(timeIntervalSince1970:Double(p.date)).formatted(.dateTime.month().day()) }
  var body: some View {
    if let first = points.first, let last = points.last {
      let i = min(max(index ?? (points.count-1),0),points.count-1), selected = points[i]
      VStack(alignment:.leading,spacing:8) {
        Text("\(day(selected)) · \(selected.heat.formatted())").font(.caption.monospacedDigit())
        GeometryReader { g in
          Canvas { c, size in
            let inset: CGFloat = 6, w = max(0,size.width-2*inset), h = max(0,size.height-2*inset)
            let low = Double(points.map(\.heat).min() ?? 0), high = Double(points.map(\.heat).max() ?? 0)
            func pt(_ n:Int) -> CGPoint {
              let x = points.count > 1 ? Double(n)/Double(points.count-1) : 0.5
              let y = high > low ? (Double(points[n].heat)-low)/(high-low) : 0.5
              return CGPoint(x:inset+w*x,y:inset+h*(1-y))
            }
            var path = Path(); path.move(to:pt(0))
            for n in points.indices.dropFirst() { path.addLine(to:pt(n)) }
            c.stroke(path,with:.color(.accentColor),lineWidth:2)
            let p = pt(i); c.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.accentColor))
          }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { v in
            index = Int((min(max(0,(v.location.x-6)/max(g.size.width-12,1)),1)*CGFloat(points.count-1)).rounded())
          })
        }.frame(height:120)
        HStack { Text(day(first));Spacer();Text(day(last)) }.font(.caption2).foregroundStyle(.secondary)
      }.accessibilityElement(children:.ignore).accessibilityLabel("每日热度")
        .accessibilityValue("\(day(selected))，\(selected.heat)")
        .accessibilityAdjustableAction { direction in
          if direction == .increment { index = min(i+1,points.count-1) }
          else if direction == .decrement { index = max(i-1,0) }
        }
    }
  }
}
