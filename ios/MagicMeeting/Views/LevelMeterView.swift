import SwiftUI

struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(8, geometry.size.width * CGFloat(level)))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}
