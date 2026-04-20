import Cocoa
import simd

// MARK: - Tool mode

enum ToolMode {
    case add        // click to add a body
    case select     // click / drag to select
    case delete     // click to delete
}

// MARK: - Selection tool sub-type

enum SelectionKind {
    case rectangle
    case lasso
}

// MARK: - SimulationViewController

final class SimulationViewController: NSViewController {

    // MARK: Sub-components
    private var metalView:  GravMetalView!
    private var renderer:   MetalRenderer!
    private var simulation: GravitySimulation!

    // MARK: Toolbar outlets
    private var toolbar:         NSView!
    private var playPauseButton: NSButton!
    private var addButton:       NSButton!
    private var selectButton:    NSButton!
    private var deleteButton:    NSButton!
    private var rectSelButton:   NSButton!
    private var lassoSelButton:  NSButton!
    private var shapePopup:      NSPopUpButton!
    private var bodyCountLabel:  NSTextField!
    private var spinLabel:       NSTextField!
    private var spinStepper:     NSStepper!
    private var tableButton:     NSButton!

    // MARK: Inspector table
    private var splitView: NSSplitView!
    private var tableView: NSTableView!
    private var tableScrollView: NSScrollView!
    private var showsTable: Bool = true
    private var hasPerformedInitialLayout: Bool = false

    // MARK: Interaction state
    private var toolMode:      ToolMode      = .add
    private var selectionKind: SelectionKind = .rectangle

    // Drag state
    private var isDragging:    Bool          = false
    private var groupDragBodies:  [Body]     = []
    private var groupDragOffsets: [SIMD2<Float>] = []
    private var lastDragWorld: SIMD2<Float>  = .zero
    private var dragVelocityBuffer: SIMD2<Float> = .zero

    // Selection drawing
    private var selectionStart:  SIMD2<Float>? = nil
    private var lassoPoints:     [SIMD2<Float>] = []

    // Shape editor
    private var shapeEditorVC: ShapeEditorViewController?

    // Physics timer drives simulation steps at fixed rate
    private var physicsTimer: Timer?
    private let physicsHz: Double = 60

    // MARK: - Lifecycle

    override func loadView() {
        let rootView = SimulationRootView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        rootView.controller = self
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device.")
        }

        // Set up simulation
        do {
            simulation = try GravitySimulation(device: device)
            simulation.loadDemoScene()
            simulation.isPaused = true
            simulation.timeStep = 0.1   // Larger dt makes orbital velocity changes visible immediately
        } catch {
            fatalError("Failed to create simulation: \(error)")
        }

        // Set up Metal view (auto-layout handled after toolbar)
        metalView = GravMetalView(frame: .zero, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1)

        // Set up renderer
        do {
            renderer = try MetalRenderer(device: device, pixelFormat: metalView.colorPixelFormat)
        } catch {
            fatalError("Failed to create renderer: \(error)")
        }
        renderer.simulation = simulation
        metalView.delegate  = renderer

        // Build toolbar FIRST so we can anchor metalView below it
        buildToolbar()

        // Build inspector table (virtualized NSTableView)
        buildInspectorTable()

        // Use split view so the table can be toggled/collapsed with no layout thrashing
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(metalView)
        splitView.addArrangedSubview(tableScrollView)

        view.addSubview(splitView)
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Simulation update → HUD + optional table refresh.
        // When table is hidden we skip reloadData() entirely for zero performance cost.
        simulation.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.updateHUD()
                self?.updateTable()
            }
        }

        startPhysicsTimer()
        updateHUD()
        updateToolButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        if !hasPerformedInitialLayout {
            hasPerformedInitialLayout = true
            if showsTable && splitView != nil {
                // Make table visible by default (~32% of width)
                let targetWidth = view.bounds.width * 0.68
                splitView.setPosition(targetWidth, ofDividerAt: 0)
            } else if splitView != nil {
                splitView.setPosition(view.bounds.width - 1, ofDividerAt: 0)
            }
        }
        // Ensure renderer has correct view size after layout and split positioning.
        // This prevents all bodies from appearing stacked in the center due to stale (1x1) viewSize.
        renderer.viewSize = metalView.drawableSize
        simulation.rebuildGPUState()
    }

    // MARK: - Toolbar construction

    private func buildToolbar() {
        toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.95).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing     = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets  = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        // Play / Pause
        playPauseButton = makeToolButton("⏸", tip: "Pause / Play (Space)", action: #selector(togglePause))

        // Tool group
        addButton    = makeToolButton("＋", tip: "Add body (A)",     action: #selector(selectAddTool))
        selectButton = makeToolButton("↖",  tip: "Select / Drag (S)", action: #selector(selectSelectTool))
        deleteButton = makeToolButton("✕",  tip: "Delete body (D)",  action: #selector(selectDeleteTool))

        // Selection sub-tools (only meaningful in select mode)
        rectSelButton  = makeToolButton("▭", tip: "Rectangle select", action: #selector(useRectSelect))
        lassoSelButton = makeToolButton("⌓", tip: "Lasso select",     action: #selector(useLassoSelect))

        // Shape popup
        shapePopup = NSPopUpButton()
        shapePopup.addItems(withTitles: ["Circle", "Rectangle", "Triangle"])
        shapePopup.addItem(withTitle: "Custom…")
        shapePopup.target = self
        shapePopup.action = #selector(shapePopupChanged(_:))
        shapePopup.toolTip = "Shape to add"
        shapePopup.font    = NSFont.systemFont(ofSize: 11)

        // Spin control
        spinLabel = NSTextField(labelWithString: "Spin:")
        spinLabel.textColor = .secondaryLabelColor
        spinLabel.font      = NSFont.systemFont(ofSize: 11)

        spinStepper = NSStepper()
        spinStepper.minValue   = -20
        spinStepper.maxValue   =  20
        spinStepper.increment  =  0.5
        spinStepper.valueWraps = false
        spinStepper.target     = self
        spinStepper.action     = #selector(spinStepperChanged(_:))
        spinStepper.toolTip    = "Spin selected body (also: scroll wheel)"

        // Inspector table toggle
        tableButton = makeToolButton("≡", tip: "Toggle data table (T)", action: #selector(toggleTable))
        tableButton.setButtonType(.pushOnPushOff)

        // Body count
        bodyCountLabel = NSTextField(labelWithString: "0 bodies")
        bodyCountLabel.textColor = .secondaryLabelColor
        bodyCountLabel.font      = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bodyCountLabel.alignment = .right

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for v: NSView in [playPauseButton,
                          sep(),
                          addButton, selectButton, deleteButton,
                          sep(),
                          rectSelButton, lassoSelButton,
                          sep(),
                          shapePopup,
                          sep(),
                          spinLabel, spinStepper,
                          sep(),
                          tableButton,
                          spacer,
                          bodyCountLabel] {
            stack.addArrangedSubview(v)
        }

        toolbar.addSubview(stack)
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),

            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func makeToolButton(_ title: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font       = NSFont.systemFont(ofSize: 13)
        b.toolTip    = tip
        b.setButtonType(.momentaryLight)
        return b
    }

    private func sep() -> NSView {
        let b = NSBox(); b.boxType = .separator
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return b
    }

    // MARK: - Inspector Table Setup (virtualized, zero-cost when hidden)

    private func buildInspectorTable() {
        tableScrollView = NSScrollView()
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .bezelBorder
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        // Enable multiple row selection for shift/command-click
        tableView.allowsMultipleSelection = true
        tableView.identifier = NSUserInterfaceItemIdentifier("BodyTable")

        let columnData: [(identifier: String, title: String, width: CGFloat)] = [
            ("id",       "ID",       68),
            ("shape",    "Shape",    78),
            ("posX",     "Pos X",    78),
            ("posY",     "Pos Y",    78),
            ("velX",     "Vel X",    78),
            ("velY",     "Vel Y",    78),
            ("mass",     "Mass",     72),
            ("size",     "Size",     72),
            ("color",    "Color",    110)
        ]

        for (id, title, width) in columnData {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }

        tableScrollView.documentView = tableView
    }

    // MARK: - Coordinate transforms (matrix-based as hinted)

    private var viewToWorldMatrix: float4x4 {
        let size = metalView.bounds.size
        guard size.width > 0 && size.height > 0 else { return matrix_identity_float4x4 }

        let ar = Float(size.width / size.height)
        let scale = camera.scale

        let viewToNDC = float4x4(
            columns: (
                SIMD4(2 / Float(size.width), 0, 0, 0),
                SIMD4(0, 2 / Float(size.height), 0, 0),
                SIMD4(0, 0, 1, 0),
                SIMD4(-1, -1, 0, 1)
            )
        )

        let ndcToWorld = float4x4(
            columns: (
                SIMD4(scale, 0, 0, camera.center.x),
                SIMD4(0, scale / ar, 0, camera.center.y),
                SIMD4(0, 0, 1, 0),
                SIMD4(0, 0, 0, 1)
            )
        )

        return ndcToWorld * viewToNDC
    }

    private var worldToViewMatrix: float4x4 {
        viewToWorldMatrix.inverse
    }

    // MARK: - Physics timer

    private func startPhysicsTimer() {
        physicsTimer?.invalidate()
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / physicsHz, repeats: true) { [weak self] _ in
            self?.simulation.step()
        }
    }

    // MARK: - HUD update

    func updateHUD() {
        bodyCountLabel.stringValue = "\(simulation.bodies.count) bodies"
        playPauseButton.title = simulation.isPaused ? "▶" : "⏸"
        if let sel = simulation.bodies.first(where: { $0.isSelected }) {
            spinStepper.doubleValue = Double(sel.angularVelocity)
        }
        tableButton.state = showsTable ? .on : .off
    }

    private func updateTable() {
        // Guarded so there is literally zero table-related work when hidden.
        // NSTableView itself is virtualized (only visible rows are materialized).
        guard showsTable else { return }
        tableView.reloadData()
        // Re-sync table selection after reload to preserve it
        updateTableSelection()
    }

    private func updateToolButtons() {
        addButton.state    = toolMode == .add    ? .on : .off
        selectButton.state = toolMode == .select ? .on : .off
        deleteButton.state = toolMode == .delete ? .on : .off
        rectSelButton.state  = selectionKind == .rectangle ? .on : .off
        lassoSelButton.state = selectionKind == .lasso     ? .on : .off
        let inSel = toolMode == .select
        rectSelButton.isEnabled  = inSel
        lassoSelButton.isEnabled = inSel
    }

    // MARK: - Camera helpers

    private var camera: Camera {
        get { renderer.camera }
        set { renderer.camera = newValue }
    }

    private func worldPoint(from event: NSEvent) -> SIMD2<Float> {
        let p = metalView.convert(event.locationInWindow, from: nil)
        let size = metalView.bounds.size
        guard size.width > 0 && size.height > 0 else {
            return .zero
        }

        let transform = viewToWorldMatrix
        let viewP = SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
        let worldP = transform * viewP
        return SIMD2<Float>(worldP.x, worldP.y)
    }

    // MARK: - Menu / toolbar actions

    @objc func togglePause(_ sender: Any? = nil) {
        simulation.isPaused.toggle()
        if !simulation.isPaused { simulation.deselectAll() }
        updateHUD()
    }

    @objc func resetSimulation(_ sender: Any? = nil) {
        simulation.loadDemoScene()
        updateHUD()
    }

    @objc override func selectAll(_ sender: Any? = nil) {
        simulation.selectAll()
        updateHUD()
        // Sync table selection after simulation change
        updateTableSelection()
    }

    @objc func deleteSelected(_ sender: Any? = nil) {
        simulation.bodies.filter { $0.isSelected }.forEach {
            renderer.evictIndexBuffer(for: $0.id)
        }
        simulation.removeSelectedBodies()
        updateHUD()
        // Sync table selection (though likely empty after delete)
        updateTableSelection()
    }

    @objc private func selectAddTool()    { toolMode = .add;    simulation.deselectAll(); updateToolButtons() }
    @objc private func selectSelectTool() { toolMode = .select; updateToolButtons() }
    @objc private func selectDeleteTool() { toolMode = .delete; simulation.deselectAll(); updateToolButtons() }

    @objc private func useRectSelect()  { selectionKind = .rectangle; updateToolButtons() }
    @objc private func useLassoSelect() { selectionKind = .lasso;     updateToolButtons() }

    @objc private func shapePopupChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 0: simulation.currentTemplate = .circle(radius: 30)
        case 1: simulation.currentTemplate = .rectangle(width: 60, height: 40)
        case 2: simulation.currentTemplate = .triangle(radius: 35)
        default:
            openShapeEditor()
        }
        toolMode = .add
        updateToolButtons()
    }

    @objc func openShapeEditor(_ sender: Any? = nil) {
        shapeEditorVC = ShapeEditorViewController.showPanel(
            relativeTo: view.window, delegate: self)
    }

    @objc private func spinStepperChanged(_ sender: NSStepper) {
        let val = Float(sender.doubleValue)
        simulation.bodies.filter { $0.isSelected }.forEach { $0.angularVelocity = val }
        simulation.rebuildGPUState()
    }

    @objc private func toggleTable(_ sender: Any? = nil) {
        showsTable.toggle()

        if showsTable {
            tableScrollView.isHidden = false
            // Reveal right pane (roughly 1/3 of window)
            let targetWidth = view.bounds.width * 0.68
            splitView.setPosition(targetWidth, ofDividerAt: 0)
        } else {
            tableScrollView.isHidden = true
            // Collapse table pane
            splitView.setPosition(view.bounds.width - 1, ofDividerAt: 0)
        }

        renderer.viewSize = metalView.drawableSize
        simulation.rebuildGPUState()

        updateHUD()
        if showsTable {
            updateTable()
        }
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let world = worldPoint(from: event)

        switch toolMode {
        case .add:
            addBodyAt(world)

        case .delete:
            if let b = simulation.body(at: world) {
                renderer.evictIndexBuffer(for: b.id)
                simulation.removeBody(b)
            }
            updateHUD()

        case .select:
            if let b = simulation.body(at: world) {
                // Clicking an unselected body clears current selection
                if !b.isSelected { simulation.deselectAll() }
                b.isSelected = true
                // Mark dragged bodies as static so physics doesn't overwrite positions
                groupDragBodies  = simulation.bodies.filter { $0.isSelected }
                groupDragOffsets = groupDragBodies.map { $0.position - world }
                groupDragBodies.forEach { $0.isStatic = true }
                simulation.rebuildGPUState()
                isDragging     = true
                lastDragWorld  = world
                dragVelocityBuffer = .zero
            } else {
                // Start selection tool
                simulation.deselectAll()
                isDragging     = false
                selectionStart = world
                lassoPoints    = [world]
                updateSelectionOverlay(to: world)
            }
        }
        updateHUD()
        // Sync table selection after any selection change in mouseDown
        updateTableSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        let world = worldPoint(from: event)

        if toolMode == .select {
            if isDragging && !groupDragBodies.isEmpty {
                let delta = world - lastDragWorld
                dragVelocityBuffer = delta * Float(physicsHz)   // estimate velocity for throw
                for (i, b) in groupDragBodies.enumerated() {
                    b.position = world + groupDragOffsets[i]
                }
                simulation.rebuildGPUState()
                lastDragWorld = world
                // Update table to show new positions during drag
                updateTable()
            } else if selectionStart != nil {
                updateSelectionOverlay(to: world)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let world = worldPoint(from: event)

        if toolMode == .select {
            if isDragging {
                // Restore physics for dragged bodies; give them throw velocity
                groupDragBodies.forEach { b in
                    b.isStatic = false
                    b.velocity = dragVelocityBuffer
                }
                simulation.rebuildGPUState()
                isDragging       = false
                groupDragBodies  = []
                groupDragOffsets = []
                dragVelocityBuffer = .zero
            } else if selectionStart != nil {
                finaliseSelection(at: world)
                selectionStart = nil
                lassoPoints    = []
                renderer.selectionOverlay.isActive = false
                // Sync table selection after finalizing scene selection
                updateTableSelection()
            }
        }
        updateHUD()
    }

    override func scrollWheel(with event: NSEvent) {
        // Ctrl+scroll → zoom camera
        if event.modifierFlags.contains(.control) {
            let factor = 1.0 + Float(event.deltaY) * 0.05
            camera.scale = max(10, min(camera.scale * factor, 5000))
            return
        }
        // Scroll on selected bodies → change their spin
        let selected = simulation.bodies.filter { $0.isSelected }
        if !selected.isEmpty {
            let delta = Float(event.deltaX + event.deltaY) * 0.3
            selected.forEach { $0.angularVelocity += delta }
            simulation.rebuildGPUState()
            updateHUD()
        } else {
            // Pan camera (world units per scroll tick proportional to zoom level)
            let pan: Float = camera.scale * 0.003
            camera.center.x -= Float(event.deltaX) * pan
            camera.center.y -= Float(event.deltaY) * pan
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let world = worldPoint(from: event)
        if let b = simulation.body(at: world) {
            renderer.evictIndexBuffer(for: b.id)
            simulation.removeBody(b)
            updateHUD()
            // Sync table selection (removal might affect indices, but likely no change)
            updateTableSelection()
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:                                    // Space
            togglePause()
        case 51, 117:                               // Delete / Fwd-delete
            deleteSelected()
        case 0:                                     // A
            selectAddTool()
        case 1:                                     // S
            selectSelectTool()
        case 2:                                     // D
            selectDeleteTool()
        case 15:                                    // R
            resetSimulation()
        case 17:                                    // T
            toggleTable()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Add body

    private let bodyColors: [SIMD4<Float>] = [
        SIMD4(0.9, 0.4, 0.3, 1), SIMD4(0.4, 0.8, 0.5, 1),
        SIMD4(0.4, 0.6, 1.0, 1), SIMD4(1.0, 0.8, 0.3, 1),
        SIMD4(0.8, 0.4, 0.9, 1), SIMD4(0.4, 0.9, 0.9, 1),
    ]
    private var colorIndex = 0

    private func addBodyAt(_ position: SIMD2<Float>) {
        let color = bodyColors[colorIndex % bodyColors.count]
        colorIndex += 1
        let body = simulation.currentTemplate.makeBody(at: position, color: color)
        simulation.addBody(body)
        updateHUD()
    }

    // MARK: - Selection overlay

    private func updateSelectionOverlay(to worldEnd: SIMD2<Float>) {
        switch selectionKind {
        case .rectangle:
            guard let start = selectionStart else { return }
            let rect = CGRect(
                x:      CGFloat(min(start.x, worldEnd.x)),
                y:      CGFloat(min(start.y, worldEnd.y)),
                width:  CGFloat(abs(worldEnd.x - start.x)),
                height: CGFloat(abs(worldEnd.y - start.y)))
            renderer.selectionOverlay.kind     = .rect(rect)
            renderer.selectionOverlay.isActive = true

        case .lasso:
            lassoPoints.append(worldEnd)
            renderer.selectionOverlay.kind     = .lasso(lassoPoints.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            renderer.selectionOverlay.isActive = true
        }
    }

    private func finaliseSelection(at worldEnd: SIMD2<Float>) {
        switch selectionKind {
        case .rectangle:
            guard let start = selectionStart else { return }
            let rect = CGRect(
                x:      CGFloat(min(start.x, worldEnd.x)),
                y:      CGFloat(min(start.y, worldEnd.y)),
                width:  CGFloat(abs(worldEnd.x - start.x)),
                height: CGFloat(abs(worldEnd.y - start.y)))
            simulation.bodies(inRect: rect).forEach { $0.isSelected = true }

        case .lasso:
            if lassoPoints.count >= 3 {
                simulation.bodies(inLasso: lassoPoints).forEach { $0.isSelected = true }
            }
        }
    }

    // MARK: - Table helpers (used by data source)

    private func shapeDescription(for body: Body) -> String {
        let count = body.localVertices.count
        if count >= 24 && count <= 64 {
            return "Circle"
        } else if count == 3 {
            return "Triangle"
        } else if count == 4 {
            return "Rectangle"
        } else {
            return "Poly(\(count))"
        }
    }

    private func shortID(for body: Body) -> String {
        String(body.id.uuidString.prefix(8))
    }

    // NEW: Flag to prevent selection syncing loops
    private var isSyncingSelection = false

    // Helper to sync table selection based on simulation
    private func updateTableSelection() {
        guard showsTable && !isSyncingSelection else { return }  // Skip if hidden or already syncing
        isSyncingSelection = true
        var indices = IndexSet()
        for (index, body) in simulation.bodies.enumerated() {
            if body.isSelected {
                indices.insert(index)
            }
        }
        tableView.selectRowIndexes(indices, byExtendingSelection: false)
        isSyncingSelection = false
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SimulationViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        simulation.bodies.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < simulation.bodies.count else { return nil }
        let body = simulation.bodies[row]
        guard let column = tableColumn else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("DataCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if cell == nil {
            cell = NSTableCellView()
            let textField = NSTextField()
            textField.isEditable = false
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.drawsBackground = false
            textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cell?.textField = textField
            cell?.addSubview(textField)
            cell?.identifier = identifier

            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
        }

        let textField = cell!.textField!
        textField.textColor = .labelColor
        textField.stringValue = ""

        switch column.identifier.rawValue {
        case "id":
            textField.stringValue = shortID(for: body)

        case "shape":
            textField.stringValue = shapeDescription(for: body)

        case "posX":
            textField.stringValue = String(format: "%.2f", body.position.x)

        case "posY":
            textField.stringValue = String(format: "%.2f", body.position.y)

        case "velX":
            textField.stringValue = String(format: "%.3f", body.velocity.x)  // more precision so orbital changes are visible

        case "velY":
            textField.stringValue = String(format: "%.3f", body.velocity.y)  // more precision so orbital changes are visible

        case "mass":
            textField.stringValue = String(format: "%.1f", body.mass)

        case "size":
            textField.stringValue = String(format: "r=%.1f", body.boundingRadius())

        case "color":
            let c = body.color
            textField.stringValue = String(format: "%.1f %.1f %.1f", c.x, c.y, c.z)
            textField.textColor = NSColor(red: CGFloat(c.x),
                                          green: CGFloat(c.y),
                                          blue: CGFloat(c.z),
                                          alpha: CGFloat(c.w))

        default:
            break
        }

        return cell
    }

    // Handle table selection changes to sync with simulation
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }  // Prevent loops from programmatic changes
        let selectedRows = tableView.selectedRowIndexes
        simulation.deselectAll()
        for row in selectedRows {
            if row < simulation.bodies.count {
                simulation.bodies[row].isSelected = true
            }
        }
        simulation.rebuildGPUState()  // Ensure scene reflects selection
        updateHUD()
    }
}

// MARK: - ShapeEditorDelegate

extension SimulationViewController: ShapeEditorDelegate {
    func shapeEditor(_ editor: ShapeEditorViewController, didFinishWith vertices: [SIMD2<Float>]) {
        simulation.currentTemplate = .custom(vertices: vertices)
        toolMode = .add
        updateToolButtons()
        shapePopup.selectItem(at: 3)   // "Custom…"
    }
}
