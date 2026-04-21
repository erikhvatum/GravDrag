import MetalKit
import AppKit

// MARK: - GravMetalView
/// MTKView that does NOT intercept events - lets them bubble to the root view.
final class GravMetalView: MTKView {
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - SimulationRootView
/// Root NSView of SimulationViewController. Intercepts all interaction events
/// and forwards them directly to the view controller, bypassing responder-chain
/// uncertainty with plain NSView.
final class SimulationRootView: NSView {
    weak var controller: SimulationViewController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        controller?.rightMouseDown(with: event)
    }
    override func otherMouseDown(with event: NSEvent) {
        controller?.otherMouseDown(with: event)
    }
    override func otherMouseDragged(with event: NSEvent) {
        controller?.otherMouseDragged(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
        controller?.otherMouseUp(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        controller?.scrollWheel(with: event)
    }
    override func keyDown(with event: NSEvent) {
        controller?.keyDown(with: event)
    }
}
