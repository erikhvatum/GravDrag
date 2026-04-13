import Cocoa
import simd

// ─────────────────────────────────────────────────────────────────────────────
// ShapeEditorViewController
// A floating panel that lets the user define an irregular convex/concave polygon
// by clicking to add vertices. Once "Use Shape" is tapped the polygon is sent
// back to the simulation as the active add-template.
// ─────────────────────────────────────────────────────────────────────────────

protocol ShapeEditorDelegate: AnyObject {
    func shapeEditor(_ editor: ShapeEditorViewController, didFinishWith vertices: [SIMD2<Float>])
}

final class ShapeEditorViewController: NSViewController {

    weak var delegate: ShapeEditorDelegate?

    private var editorView: ShapeEditorView!
    private var statusLabel: NSTextField!
    private var useButton: NSButton!
    private var clearButton: NSButton!
    private var undoButton: NSButton!

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    // MARK: - UI

    private func buildUI() {
        // Toolbar at the bottom
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing     = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        undoButton  = makeButton("Undo",  action: #selector(undoVertex))
        clearButton = makeButton("Clear", action: #selector(clearVertices))
        useButton   = makeButton("Use Shape", action: #selector(useShape))
        useButton.bezelColor = NSColor.controlAccentColor

        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(clearButton)
        toolbar.addArrangedSubview(NSView())   // spacer
        toolbar.addArrangedSubview(useButton)

        // Instruction label
        statusLabel = NSTextField(labelWithString: "Click in canvas to add vertices")
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.font      = NSFont.systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Drawing canvas
        editorView = ShapeEditorView()
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.onChange = { [weak self] in self?.updateUI() }

        view.addSubview(editorView)
        view.addSubview(statusLabel)
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            editorView.topAnchor.constraint(equalTo: view.topAnchor),
            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -4),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
        ])

        updateUI()
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func updateUI() {
        let n = editorView.vertices.count
        useButton.isEnabled = n >= 3
        if n == 0 {
            statusLabel.stringValue = "Click in canvas to add vertices (need ≥ 3)"
        } else {
            statusLabel.stringValue = "\(n) vertices — \(n >= 3 ? "ready" : "need \(3 - n) more")"
        }
    }

    // MARK: - Actions

    @objc private func undoVertex() {
        guard !editorView.vertices.isEmpty else { return }
        editorView.vertices.removeLast()
        editorView.needsDisplay = true
        updateUI()
    }

    @objc private func clearVertices() {
        editorView.vertices.removeAll()
        editorView.needsDisplay = true
        updateUI()
    }

    @objc private func useShape() {
        guard editorView.vertices.count >= 3 else { return }
        let size  = editorView.bounds.size
        let cx    = size.width  / 2
        let cy    = size.height / 2
        let scale: Float = 1.5  // tweak to taste

        // Convert view coords (y-down) → local body space (y-up), centred & scaled
        let rawVerts = editorView.vertices.map { p -> SIMD2<Float> in
            SIMD2<Float>(Float(p.x - cx) * scale, Float(cy - p.y) * scale)
        }

        // Translate so centroid is at origin
        let centroid = rawVerts.reduce(SIMD2<Float>.zero, +) / Float(rawVerts.count)
        let finalVerts = rawVerts.map { $0 - centroid }

        delegate?.shapeEditor(self, didFinishWith: finalVerts)
        view.window?.close()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ShapeEditorView
// An NSView that collects click points and draws the in-progress polygon.
// ─────────────────────────────────────────────────────────────────────────────

final class ShapeEditorView: NSView {

    var vertices: [CGPoint] = []
    var onChange: (() -> Void)?
    private var hoverPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }  // origin top-left, consistent with NSEvent

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(white: 0.08, alpha: 1)
        bg.setFill()
        bounds.fill()

        // Grid
        NSColor(white: 0.15, alpha: 1).setStroke()
        let grid = NSBezierPath()
        let step: CGFloat = 30
        var x = step
        while x < bounds.width { grid.move(to: CGPoint(x: x, y: 0)); grid.line(to: CGPoint(x: x, y: bounds.height)); x += step }
        var y = step
        while y < bounds.height { grid.move(to: CGPoint(x: 0, y: y)); grid.line(to: CGPoint(x: bounds.width, y: y)); y += step }
        grid.lineWidth = 0.5
        grid.stroke()

        guard !vertices.isEmpty else { return }

        // Polygon fill
        let poly = NSBezierPath()
        poly.move(to: vertices[0])
        for v in vertices.dropFirst() { poly.line(to: v) }
        if let h = hoverPoint { poly.line(to: h) }
        poly.close()
        NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.15).setFill()
        poly.fill()

        // Polygon outline
        NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 0.9).setStroke()
        poly.lineWidth = 1.5
        poly.stroke()

        // Preview edge to cursor
        if let h = hoverPoint, vertices.count >= 1 {
            let ghost = NSBezierPath()
            ghost.move(to: vertices.last!)
            ghost.line(to: h)
            NSColor(white: 0.6, alpha: 0.5).setStroke()
            ghost.lineWidth = 1
            let pattern: [CGFloat] = [4, 4]
            ghost.setLineDash(pattern, count: 2, phase: 0)
            ghost.stroke()
        }

        // Vertex dots
        for (i, v) in vertices.enumerated() {
            let r: CGFloat = i == 0 ? 6 : 4
            let dot = NSBezierPath(ovalIn: CGRect(x: v.x - r, y: v.y - r, width: r*2, height: r*2))
            (i == 0 ? NSColor(red: 1, green: 0.6, blue: 0.3, alpha: 1) :
                      NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1)).setFill()
            dot.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        vertices.append(p)
        needsDisplay = true
        onChange?()
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Convenience: Show editor in a panel
// ─────────────────────────────────────────────────────────────────────────────

extension ShapeEditorViewController {
    static func showPanel(relativeTo parentWindow: NSWindow?,
                          delegate: ShapeEditorDelegate) -> ShapeEditorViewController {
        let vc = ShapeEditorViewController()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "Shape Editor"
        panel.contentViewController = vc
        panel.isFloatingPanel = true
        vc.delegate = delegate
        if let pw = parentWindow {
            panel.setFrameTopLeftPoint(NSPoint(
                x: pw.frame.maxX - 380,
                y: pw.frame.maxY - 60))
        }
        panel.makeKeyAndOrderFront(nil)
        return vc
    }
}
