import SwiftUI
import AppKit

struct ReadingAidsOverlay: View {
    var preset: ReadingPreset
    @Binding var rulerY: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if preset.overlayEnabled {
                    preset.overlayColor
                        .opacity(preset.overlayOpacity)
                        .allowsHitTesting(false)
                }

                if preset.dimSurroundEnabled || preset.lineFocusEnabled {
                    FocusMask(
                        lineCount: preset.lineFocusEnabled ? preset.lineFocusLineCount : 0,
                        fade: preset.lineFocusFade,
                        dimOpacity: preset.dimSurroundEnabled ? preset.dimSurroundOpacity : preset.lineFocusFade,
                        focusCenterY: preset.rulerEnabled ? rulerY : geo.size.height * 0.4,
                        lineHeight: CGFloat(preset.fontSize + preset.lineSpacing + 8),
                        enabledDim: true
                    )
                    .allowsHitTesting(false)
                }

                if preset.rulerEnabled {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(preset.rulerColor.opacity(preset.rulerOpacity))
                        .frame(width: geo.size.width, height: preset.rulerHeight)
                        .blur(radius: max(0, preset.rulerSoftness * 0.12))
                        .position(x: geo.size.width / 2, y: rulerY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    rulerY = min(max(20, value.location.y), geo.size.height - 20)
                                }
                        )
                }

                if preset.pageFocusEnabled {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.35),
                            Color.clear,
                            Color.clear,
                            Color.black.opacity(0.35)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                if rulerY <= 0 { rulerY = geo.size.height * 0.4 }
            }
        }
    }
}

private struct FocusMask: View {
    var lineCount: Int
    var fade: Double
    var dimOpacity: Double
    var focusCenterY: CGFloat
    var lineHeight: CGFloat
    var enabledDim: Bool

    var body: some View {
        Canvas { context, size in
            guard enabledDim else { return }
            let band: CGFloat = lineCount > 0
                ? CGFloat(max(lineCount, 1)) * lineHeight
                : size.height * 0.35
            let top = max(0, focusCenterY - band / 2)
            let bottom = min(size.height, focusCenterY + band / 2)

            context.fill(
                Path(CGRect(x: 0, y: 0, width: size.width, height: top)),
                with: .color(.black.opacity(dimOpacity))
            )
            context.fill(
                Path(CGRect(x: 0, y: bottom, width: size.width, height: max(0, size.height - bottom))),
                with: .color(.black.opacity(dimOpacity))
            )
        }
    }
}
