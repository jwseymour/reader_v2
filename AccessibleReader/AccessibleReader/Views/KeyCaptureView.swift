import SwiftUI
import AppKit

/// Captures key events for reading aids (ruler move, overlay opacity) without stealing text input.
struct KeyCaptureView: NSViewRepresentable {
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyView)?.onKey = onKey
    }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.window?.firstResponder is NSTextView || self?.window?.firstResponder is NSTextField {
                    return event
                }
                self?.onKey?(event)
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
