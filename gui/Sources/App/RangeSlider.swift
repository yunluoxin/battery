import SwiftUI

/// Single-thumb slider sharing the RangeSlider visual style.
struct StyledSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 20...100

    var body: some View {
        RangeSlider(lower: .constant(range.lowerBound), upper: $value, range: range, lowerEnabled: false)
    }
}

/// Two-thumb range slider over a percentage domain.
/// When `lowerEnabled` is false, only the upper thumb is interactive and the
/// lower thumb is pinned to the upper value.
///
/// Rewritten for reliable hit-testing: each thumb is a plain view with an
/// enlarged content shape, and the drag is applied via simultaneousGesture so
/// the slider doesn't fight with popover hit-testing.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    var range: ClosedRange<Double> = 20...100
    var lowerEnabled: Bool = true

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                track(width: width)
                lowerThumb(width: width)
                upperThumb(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: thumbSize + 8)
    }

    // MARK: Track

    private func track(width: CGFloat) -> some View {
        // Single-thumb mode fills from the track's left edge; range mode fills
        // between the two thumbs.
        let fillStart = lowerEnabled ? xPosition(for: lower, width: width) : 0
        let fillEnd = xPosition(for: upper, width: width)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: trackHeight)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(fillEnd - fillStart, 0), height: trackHeight)
                .offset(x: fillStart)
        }
        .frame(height: thumbSize + 8, alignment: .center)
    }

    // MARK: Thumbs

    private func lowerThumb(width: CGFloat) -> some View {
        thumb(value: $lower, constrainedTo: range.lowerBound...upper, width: width)
            .opacity(lowerEnabled ? 1 : 0)
            .allowsHitTesting(lowerEnabled)
    }

    private func upperThumb(width: CGFloat) -> some View {
        thumb(value: $upper, constrainedTo: (lowerEnabled ? lower : range.lowerBound)...range.upperBound, width: width)
    }

    private func thumb(value: Binding<Double>, constrainedTo bounds: ClosedRange<Double>, width: CGFloat) -> some View {
        Circle()
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(width: thumbSize, height: thumbSize)
            .contentShape(Circle().scale(1.8))  // generous hit area
            .offset(x: xPosition(for: value.wrappedValue, width: width) - thumbSize / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = valueFor(x: drag.location.x, width: width)
                        value.wrappedValue = min(max(newValue, bounds.lowerBound), bounds.upperBound)
                    }
            )
    }

    // MARK: Conversion

    private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let fraction = (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(fraction) * width
    }

    private func valueFor(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return range.lowerBound }
        let fraction = max(0, min(1, Double(x / width)))
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return (raw / 5).rounded() * 5  // snap to 5% steps
    }
}
