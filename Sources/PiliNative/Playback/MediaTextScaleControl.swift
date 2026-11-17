import SwiftUI

struct MediaTextScaleControl: View {
  let title: String
  @Binding var points: Double
  var base: Double = 15
  var body: some View {
    let scale = Binding<Double>(
      get: { min(2.5, max(0.5, points / base)) },
      set: { points = (($0 * 100).rounded() / 100) * base })
    LabeledContent(title) { Text((points / base).formatted(.percent.precision(.fractionLength(0)))) }
    Slider(value: scale, in: 0.5...2.5, step: 0.01).accessibilityLabel(title)
  }
}
