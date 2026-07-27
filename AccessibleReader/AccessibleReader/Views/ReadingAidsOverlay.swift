import SwiftUI
import AppKit

struct ReadingAidsOverlay: View {
    var preset: ReadingPreset
    @Binding var focusY: CGFloat

    @State private var pointerInside = false
    @State private var surfaceHeight: CGFloat = 0

    /// Just above vertical centre when the pointer is not over the page.
    private var defaultFocusY: CGFloat {
        max(20, surfaceHeight * 0.42)
    }

    private var activeFocusY: CGFloat {
        if focusY > 0 { return focusY }
        return defaultFocusY
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Pass-through mouse tracking for focus band
                MouseYTracker { y in
                    surfaceHeight = geo.size.height
                    if let y {
                        pointerInside = true
                        focusY = min(max(20, y), geo.size.height - 20)
                    } else if pointerInside {
                        pointerInside = false
                        focusY = geo.size.height * 0.42
                    }
                }
                .allowsHitTesting(false)

                if preset.overlayEnabled {
                    preset.overlayColor
                        .opacity(preset.overlayOpacity)
                        .allowsHitTesting(false)
                }

                if preset.dimSurroundEnabled || preset.lineFocusEnabled {
                    FocusMask(
                        lineCount: preset.lineFocusEnabled ? preset.lineFocusLineCount : 0,
                        dimOpacity: preset.dimSurroundEnabled ? preset.dimSurroundOpacity : preset.lineFocusFade,
                        fadeStrength: preset.lineFocusEnabled ? preset.lineFocusFade : 0.55,
                        focusCenterY: activeFocusY,
                        lineHeight: ReaderFont.displaySize(for: preset) + CGFloat(preset.lineSpacing) + 8
                    )
                    .allowsHitTesting(false)
                }

                if preset.rulerEnabled {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(preset.rulerColor.opacity(preset.rulerOpacity))
                        .frame(width: geo.size.width, height: preset.rulerHeight)
                        .blur(radius: max(0, preset.rulerSoftness * 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(preset.rulerColor.opacity(0.35), lineWidth: 1)
                        )
                        .position(x: geo.size.width / 2, y: activeFocusY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    focusY = min(max(20, value.location.y), geo.size.height - 20)
                                }
                        )
                }

                if preset.pageFocusEnabled {
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.42), location: 0),
                            .init(color: Color.black.opacity(0.18), location: 0.12),
                            .init(color: Color.clear, location: 0.28),
                            .init(color: Color.clear, location: 0.72),
                            .init(color: Color.black.opacity(0.18), location: 0.88),
                            .init(color: Color.black.opacity(0.42), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                surfaceHeight = geo.size.height
                if focusY <= 0 {
                    focusY = geo.size.height * 0.42
                }
            }
            .onChange(of: geo.size.height) { _, newHeight in
                surfaceHeight = newHeight
                if !pointerInside {
                    focusY = newHeight * 0.42
                }
            }
        }
    }
}

/// Tracks mouse Y in flipped coordinates (0 = top), without stealing clicks or scrolls.
private struct MouseYTracker: NSViewRepresentable {
    var onUpdate: (CGFloat?) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onUpdate = onUpdate
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onUpdate = onUpdate
    }

    final class TrackerView: NSView {
        var onUpdate: ((CGFloat?) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    self.onUpdate?(point.y)
                } else {
                    self.onUpdate?(nil)
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Soft gradient focus band — clear reading window with feathered edges into the dimmed surround.
private struct FocusMask: View {
    var lineCount: Int
    var dimOpacity: Double
    var fadeStrength: Double
    var focusCenterY: CGFloat
    var lineHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            let clearBand: CGFloat = lineCount > 0
                ? CGFloat(max(lineCount, 1)) * lineHeight
                : h * 0.32
            let fadePx = max(56, min(180, clearBand * (0.65 + fadeStrength * 0.75)))
            let clearTop = max(0, focusCenterY - clearBand / 2)
            let clearBottom = min(h, focusCenterY + clearBand / 2)

            let fade = fadePx / h
            let c0 = clearTop / h
            let c1 = clearBottom / h
            let dim = Color.black.opacity(dimOpacity)
            let raw: [(Color, CGFloat)] = [
                (dim, 0),
                (dim, max(0, c0 - fade)),
                (Color.black.opacity(dimOpacity * 0.45), max(0, c0 - fade * 0.35)),
                (Color.clear, c0),
                (Color.clear, c1),
                (Color.black.opacity(dimOpacity * 0.45), min(1, c1 + fade * 0.35)),
                (dim, min(1, c1 + fade)),
                (dim, 1)
            ]
            var last: CGFloat = 0
            let stops: [Gradient.Stop] = raw.map { color, loc in
                let clamped = max(last, min(1, loc))
                last = clamped
                return .init(color: color, location: clamped)
            }

            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        }
    }
}
