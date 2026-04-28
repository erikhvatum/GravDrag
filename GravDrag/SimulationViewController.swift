import Cocoa
import simd

// MARK: - Tool mode

enum ToolMode {
    case add        // click to add a body
    case select     // click / drag to select
    case delete     // click to delete
    case rosette    // click to place a Keplerian rosette
    case galaxy     // click to place a swirling galaxy
    case ship       // click to insert a controllable ship
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
    private var resetButton:     NSButton!
    private var clearButton:     NSButton!
    private var addButton:       NSButton!
    private var selectButton:    NSButton!
    private var deleteButton:    NSButton!
    private var rosetteButton:   NSButton!
    private var galaxyButton:    NSButton!
    private var shipButton:      NSButton!
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
    // Stores the table (right-pane) width in points. Width-based semantics make
    // restore robust to window-size changes and to the table being collapsed.
    private let tableWidthDefaultsKey = "SimulationTableWidth"
    private let tableVisibilityDefaultsKey = "SimulationShowsTable"
    private var isRestoringSplitPosition = false
    private var suppressSplitSaveUntilReady = true
    // Counts in-flight programmatic divider adjustments (toggle / restore). The
    // delegate ignores resize events while this is non-zero so it doesn't
    // misinterpret the transient state as a user drag and clobber persisted
    // state. A counter (rather than a Bool) avoids races between overlapping
    // programmatic adjustments.
    private var programmaticSplitAdjustments: Int = 0
    private var isProgrammaticallyAdjustingSplit: Bool { programmaticSplitAdjustments > 0 }
    // Minimum widths used when clamping table/metal widths.
    private let minTableWidth: CGFloat = 150
    private let minMetalWidth: CGFloat = 200

    // MARK: Simulation speed
    private var speedSlider: NSSlider!
    private var speedField: NSTextField!
    private let baseTimeStep: Float = 0.1
    private let minSpeed: Float = 0.00001
    private let maxSpeed: Float = 3.0
    private let speedTickCount: Int = 12
    private var speedStep: Float { (maxSpeed - minSpeed) / Float(speedTickCount - 1) }
    private var speedValue: Float = 1.0
    private var isUpdatingSpeedUI = false

    // MARK: Interaction state
    private var toolMode:      ToolMode      = .add
    private var selectionKind: SelectionKind = .rectangle

    // Drag state
    private var isDragging:    Bool          = false
    private var groupDragBodies:  [Body]     = []
    private var groupDragOffsets: [SIMD2<Float>] = []
    private var groupDragPreVelocities: [SIMD2<Float>] = []  // velocities before drag started
    private var dragStartWorld: SIMD2<Float> = .zero
    private var lastDragWorld: SIMD2<Float>  = .zero
    private var isVKeyPressed: Bool = false  // tracks V key state for velocity drag mode

    // Panning state (middle mouse button)
    private var isPanning: Bool = false
    private var panStartWorld: SIMD2<Float> = .zero
    private var panStartCamera: SIMD2<Float> = .zero

    // Selection drawing
    private var selectionStart:  SIMD2<Float>? = nil
    private var lassoPoints:     [SIMD2<Float>] = []

    // Shape editor
    private var shapeEditorVC: ShapeEditorViewController?

    // Rosette configuration
    private var rosetteCount: Int = 6
    private var rosetteMass: Float = 1.0
    private var rosetteRadius: Float = 300.0
    private var rosetteShape: ShapeTemplate = .circle(radius: 20)

    // Galaxy configuration
    private var galaxyCount: Int = 120
    private var galaxyRadius: Float = 800.0
    private var galaxyHasCentralMass: Bool = true
    private let galaxyTargetPeriod: Float = 12.0

    // Ship configuration
    // The demo triangle has radius 26 (≈52 across). A ship length of 26 is
    // therefore "about half the size" of that triangle along its longest axis.
    private var shipLength: Float = 26.0
    private var shipMass:   Float = 0  // 0 sentinel: use area-derived mass on first dialog open

    // Tracks which bodies were inserted as ships, so we can detect a
    // double-click on a ship vs any other body.
    private var shipIDs: Set<UUID> = []

    // Active ship-control state (set when a ship is double-clicked in select mode)
    private var controlledShip: Body? = nil
    private var shipControlPanel: ShipControlPanel? = nil
    private var shipThrustValue: Float = 0.30        // 0...1, slider-driven
    private var arrowKeysHeld: Set<UInt16> = []      // 123/124/125/126

    // Per-step thrust applied at slider value 1.0 (units of velocity per physics step).
    private let shipMaxThrustPerStep: Float = 30.0
    // Per-step turn rate applied while ←/→ held (radians per physics step).
    private let shipTurnPerStep: Float = 0.05

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
            simulation.timeStep = baseTimeStep   // Larger dt makes orbital velocity changes visible immediately
        } catch {
            fatalError("Failed to create simulation: \(error)")
        }

        // Set up Metal view (auto-layout handled after toolbar)
        metalView = GravMetalView(frame: .zero, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = true  // Managed by NSSplitView
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

        // Explicit initial camera (zoomed out 2x from the Camera struct default of 300
        // so the orbiting triangle is comfortably visible while centered on the sphere).
        // This must be done *after* the renderer exists.
        camera.center = .zero
        camera.scale = 600.0

        let defaults = UserDefaults.standard
        if defaults.object(forKey: tableVisibilityDefaultsKey) != nil {
            showsTable = defaults.bool(forKey: tableVisibilityDefaultsKey)
        }

        // Build toolbar FIRST so we can anchor metalView below it
        buildToolbar()

        // Build inspector table (virtualized NSTableView)
        buildInspectorTable()
        applySimulationSpeed(speedValue)

        // Use split view so the table can be toggled/collapsed with no layout thrashing
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
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
            restoreSplitViewPosition()
        }
        // Ensure renderer has correct view size after layout and split positioning.
        // This prevents all bodies from appearing stacked in the center due to stale (1x1) viewSize.
        renderer.viewSize = metalView.drawableSize
        simulation.rebuildGPUState()
        suppressSplitSaveUntilReady = false
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

        // Reset scene
        resetButton = makeToolButton("⟳", tip: "Reset Scene (R)", action: #selector(resetSimulation))

        // Clear all
        clearButton = makeToolButton("🗑", tip: "Clear all bodies", action: #selector(clearAllBodies))

        // Tool group
        addButton    = makeToolButton("＋", tip: "Add body (A)",     action: #selector(selectAddTool))
        selectButton = makeToolButton("↖",  tip: "Select / Drag (S)", action: #selector(selectSelectTool))
        deleteButton = makeToolButton("✕",  tip: "Delete body (D)",  action: #selector(selectDeleteTool))
        rosetteButton = makeToolButton("⭘", tip: "Keplerian Rosette", action: #selector(selectRosetteTool))
        galaxyButton  = makeToolButton("🌀", tip: "Galaxy Generator", action: #selector(selectGalaxyTool))
        shipButton    = makeToolButton("🚀", tip: "Insert Ship",      action: #selector(selectShipTool))

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
        spinStepper.toolTip    = "Spin selected body"

        // Inspector table toggle
        tableButton = makeToolButton("≡", tip: "Toggle data table (T)", action: #selector(toggleTable))
        tableButton.setButtonType(.pushOnPushOff)

        // Simulation speed controls
        let speedLabel = NSTextField(labelWithString: "Speed:")
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.font      = NSFont.systemFont(ofSize: 11)

        speedSlider = NSSlider(value: Double(speedValue),
                               minValue: Double(0.25),
                               maxValue: Double(maxSpeed),
                               target: self,
                               action: #selector(speedSliderChanged(_:)))
        speedSlider.numberOfTickMarks = speedTickCount
        speedSlider.allowsTickMarkValuesOnly = false
        speedSlider.isContinuous = true
        speedSlider.tickMarkPosition = .below
        speedSlider.controlSize = .small
        speedSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        speedSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        speedSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let speedFormatter = NumberFormatter()
        speedFormatter.minimum = NSNumber(value: minSpeed)
        speedFormatter.maximum = NSNumber(value: maxSpeed)
        speedFormatter.minimumFractionDigits = 5
        speedFormatter.maximumFractionDigits = 7

        speedField = NSTextField(string: String(format: "%.2f", speedValue))
        speedField.alignment = .right
        speedField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedField.formatter = speedFormatter
        speedField.target = self
        speedField.action = #selector(speedFieldChanged(_:))
        (speedField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        speedField.setContentHuggingPriority(.required, for: .horizontal)
        speedField.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let speedStack = NSStackView(views: [speedLabel, speedSlider, speedField])
        speedStack.spacing = 6
        speedStack.alignment = .centerY
        speedStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Body count
        bodyCountLabel = NSTextField(labelWithString: "0 bodies")
        bodyCountLabel.textColor = .secondaryLabelColor
        bodyCountLabel.font      = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bodyCountLabel.alignment = .right
        bodyCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        for v: NSView in [playPauseButton,
                          resetButton,
                          clearButton,
                          sep(),
                          addButton, selectButton, deleteButton, rosetteButton, galaxyButton, shipButton,
                          sep(),
                          rectSelButton, lassoSelButton,
                          sep(),
                          shapePopup,
                          sep(),
                          spinLabel, spinStepper,
                          sep(),
                          tableButton,
                          speedStack,
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
        tableScrollView.translatesAutoresizingMaskIntoConstraints = true  // Managed by NSSplitView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.borderType = .bezelBorder

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
            ("focus",    "Focus",    50),
            ("id",       "ID",       68),
            ("shape",    "Shape",    78),
            ("posX",     "Pos X",    78),
            ("posY",     "Pos Y",    78),
            ("velX",     "Vel X",    78),
            ("velY",     "Vel Y",    78),
            ("mass",     "Mass",     72),
            ("radius",   "Radius",   72),
            ("spin",     "Spin",     72),
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

    // MARK: - Coordinate transforms (uses Camera.viewToWorld for perfect match with renderer/shaders)

    private var camera: Camera {
        get { renderer.camera }
        set { renderer.camera = newValue }
    }

    private func worldPoint(from event: NSEvent) -> SIMD2<Float> {
        var viewPoint = metalView.convert(event.locationInWindow, from: nil)
        let boundsSize = metalView.bounds.size
        let drawableSize = renderer.viewSize

        // Convert points → pixels to match the renderer's drawableSize (and Camera.viewToWorld expectation).
        // This eliminates the scale factor mismatch (especially on Retina where drawableSize is 2× bounds).
        if boundsSize.width > 0 && boundsSize.height > 0 {
            let scaleX = drawableSize.width / boundsSize.width
            let scaleY = drawableSize.height / boundsSize.height
            viewPoint.x *= scaleX
            viewPoint.y *= scaleY
        }

        return camera.viewToWorld(viewPoint, viewSize: drawableSize)
    }

    // MARK: - Physics timer

    private func startPhysicsTimer() {
        physicsTimer?.invalidate()
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / physicsHz, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.applyShipControls()
            self.simulation.step()
        }
    }

    // MARK: - Simulation speed control

    private func clampedSpeed(_ value: Float) -> Float {
        max(minSpeed, min(maxSpeed, value))
    }

    private func quantizedSpeed(_ value: Float) -> Float {
        let clamped = clampedSpeed(value)
        let steps = round((clamped - minSpeed) / speedStep)
        let snapped = minSpeed + steps * speedStep
        return clampedSpeed(snapped)
    }

    private func applySimulationSpeed(_ value: Float) {
        let clamped = clampedSpeed(value)
        speedValue = clamped
        simulation.timeStep = baseTimeStep * speedValue
        updateSpeedControls()
    }

    private func updateSpeedControls() {
        guard !isUpdatingSpeedUI else { return }
        isUpdatingSpeedUI = true
        speedSlider.doubleValue = Double(speedValue)
        speedField.stringValue = String(format: "%.7f", speedValue)
        isUpdatingSpeedUI = false
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        applySimulationSpeed(Float(sender.doubleValue))
        // Snap slider position to nearest tick while preserving typed value display
        let snapped = quantizedSpeed(Float(sender.doubleValue))
        isUpdatingSpeedUI = true
        speedSlider.doubleValue = Double(snapped)
        isUpdatingSpeedUI = false
    }

    @objc private func speedFieldChanged(_ sender: NSTextField) {
        applySimulationSpeed(Float(sender.doubleValue))
    }

    // MARK: - HUD update

    func updateHUD() {
        bodyCountLabel.stringValue = "\(simulation.bodies.count) bodies"
        playPauseButton.title = simulation.isPaused ? "▶" : "⏸"
        if let sel = simulation.bodies.first(where: { $0.isSelected }) {
            spinStepper.doubleValue = Double(sel.angularVelocity)
        }
        tableButton.state = showsTable ? .on : .off

        // Pan camera to keep focused body centered
        if let focused = simulation.focusedBody {
            camera.center = focused.position
        }
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
        rosetteButton.state = toolMode == .rosette ? .on : .off
        galaxyButton.state  = toolMode == .galaxy ? .on : .off
        shipButton.state    = toolMode == .ship    ? .on : .off
        rectSelButton.state  = selectionKind == .rectangle ? .on : .off
        lassoSelButton.state = selectionKind == .lasso     ? .on : .off
        let inSel = toolMode == .select
        rectSelButton.isEnabled  = inSel
        lassoSelButton.isEnabled = inSel
    }

    // MARK: - Menu / toolbar actions

    @objc func togglePause(_ sender: Any? = nil) {
        simulation.isPaused.toggle()
        if !simulation.isPaused { simulation.deselectAll() }
        updateHUD()
    }

    @objc func resetSimulation(_ sender: Any? = nil) {
        simulation.isPaused = true
        shipIDs.removeAll()
        shipControlPanel?.close()
        simulation.loadDemoScene()
        simulation.deselectAll()
        simulation.clearFocus()
        simulation.timeStep = baseTimeStep * speedValue
        simulation.rebuildGPUState()
        camera.center = .zero
        camera.scale = 600.0  // Zoomed out 2x from the Camera default so the orbiting triangle is comfortably visible while centered on the central sphere
        renderer.selectionOverlay.isActive = false
        updateHUD()
        updateTable()
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

    @objc private func selectRosetteTool() {
        showRosetteConfigDialog()
    }

    @objc private func selectGalaxyTool() {
        showGalaxyConfigDialog()
    }

    @objc private func selectShipTool() {
        showShipConfigDialog()
    }

    @objc private func clearAllBodies() {
        // Remove all bodies from the simulation
        simulation.bodies.forEach { renderer.evictIndexBuffer(for: $0.id) }
        simulation.removeAllBodies()
        shipIDs.removeAll()
        shipControlPanel?.close()
        updateHUD()
        updateTable()
    }

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
        updateTable()
    }

    @objc private func toggleTable(_ sender: Any? = nil) {
        showsTable.toggle()
        saveTableVisibility()

        applyTableVisibility()

        renderer.viewSize = metalView.drawableSize
        simulation.rebuildGPUState()

        updateHUD()
        if showsTable {
            updateTable()
        }
    }

    /// Total horizontal extent of the split view (falls back to the controller's
    /// view bounds before the split view has been laid out).
    private var splitTotalWidth: CGFloat {
        splitView?.bounds.width ?? view.bounds.width
    }

    /// Begin a programmatic divider adjustment. Returns a token that must be
    /// passed to `endProgrammaticSplitAdjustment(_:)` once the adjustment is
    /// complete (after layout has settled on the next runloop turn).
    private func beginProgrammaticSplitAdjustment() {
        programmaticSplitAdjustments += 1
    }

    private func endProgrammaticSplitAdjustment() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.programmaticSplitAdjustments > 0 {
                self.programmaticSplitAdjustments -= 1
            }
        }
    }

    /// Drive the split view divider to match `showsTable`. When showing, the
    /// divider is placed so the table pane is exactly the user's last chosen
    /// table width; when hiding, the table pane is collapsed to zero width.
    /// The programmatic-adjustment counter is bumped so the delegate doesn't
    /// treat the resulting resize events as a manual drag.
    private func applyTableVisibility() {
        guard splitView != nil else { return }
        beginProgrammaticSplitAdjustment()
        defer { endProgrammaticSplitAdjustment() }
        if showsTable {
            let position = dividerPositionForTableWidth(desiredTableWidth())
            splitView.setPosition(position, ofDividerAt: 0)
        } else {
            // Collapse table pane to zero width. We deliberately do NOT touch
            // the persisted table width here, so that toggling the table back
            // on restores its previous width.
            splitView.setPosition(splitView.bounds.width, ofDividerAt: 0)
        }
    }

    private func saveTableVisibility() {
        UserDefaults.standard.set(showsTable, forKey: tableVisibilityDefaultsKey)
    }

    // MARK: - Split view persistence (table-width based)

    private func storedTableWidth() -> CGFloat? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: tableWidthDefaultsKey) != nil else { return nil }
        let w = CGFloat(defaults.double(forKey: tableWidthDefaultsKey))
        return w > 0 ? w : nil
    }

    private func clampedTableWidth(_ width: CGFloat) -> CGFloat {
        let maxTable = max(splitTotalWidth - minMetalWidth, minTableWidth)
        return max(minTableWidth, min(width, maxTable))
    }

    private func desiredTableWidth() -> CGFloat {
        if let saved = storedTableWidth() {
            return clampedTableWidth(saved)
        }
        return clampedTableWidth(splitTotalWidth * 0.32)
    }

    private func dividerPositionForTableWidth(_ tableWidth: CGFloat) -> CGFloat {
        return splitTotalWidth - clampedTableWidth(tableWidth)
    }

    /// Persist the current table (right-pane) width. Only saves when the table
    /// is shown and has a positive width, so the collapsed state never
    /// overwrites the user's last chosen width.
    private func saveTableWidth() {
        guard showsTable, !suppressSplitSaveUntilReady else { return }
        guard splitView != nil, splitView.arrangedSubviews.count >= 2 else { return }
        let tableWidth = splitView.arrangedSubviews[1].frame.width
        guard tableWidth > 0.5 else { return }
        UserDefaults.standard.set(Double(tableWidth), forKey: tableWidthDefaultsKey)
    }

    private func restoreSplitViewPosition() {
        guard splitView != nil else { return }
        beginProgrammaticSplitAdjustment()
        defer { endProgrammaticSplitAdjustment() }
        if showsTable {
            isRestoringSplitPosition = true
            let position = dividerPositionForTableWidth(desiredTableWidth())
            splitView.setPosition(position, ofDividerAt: 0)
            DispatchQueue.main.async { [weak self] in
                self?.isRestoringSplitPosition = false
            }
        } else {
            // Collapse table pane to zero width without disturbing the
            // persisted table width, so a later toggle-on restores it.
            splitView.setPosition(splitView.bounds.width, ofDividerAt: 0)
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

        case .rosette:
            addRosetteAt(world)
        case .galaxy:
            addGalaxyAt(world)
        case .ship:
            addShipAt(world)

        case .select:
            // Double-click on a ship enters/refreshes ship-control mode.
            if event.clickCount >= 2,
               let b = simulation.body(at: world),
               shipIDs.contains(b.id) {
                openShipControlPanel(for: b)
                updateHUD()
                return
            }
            if let b = simulation.body(at: world) {
                // Clicking an unselected body clears current selection
                if !b.isSelected { simulation.deselectAll() }
                b.isSelected = true
                // Mark dragged bodies as static so physics doesn't overwrite positions
                groupDragBodies  = simulation.bodies.filter { $0.isSelected }
                groupDragOffsets = groupDragBodies.map { $0.position - world }
                // Save pre-drag velocities so we can restore them later
                groupDragPreVelocities = groupDragBodies.map { $0.velocity }
                groupDragBodies.forEach { $0.isStatic = true }
                simulation.rebuildGPUState()
                isDragging     = true
                dragStartWorld = world
                lastDragWorld  = world
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
                for (i, b) in groupDragBodies.enumerated() {
                    b.position = world + groupDragOffsets[i]

                    // If V key is held, preview the velocity that will be applied
                    if isVKeyPressed {
                        let dragVector = world - dragStartWorld
                        let velocityScale: Float = 4.2
                        b.velocity = dragVector * velocityScale
                    }
                }
                simulation.rebuildGPUState()
                lastDragWorld = world
                // Update table to show new positions and velocities during drag
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
                if isVKeyPressed {
                    // V-click drag mode: apply velocity based on drag vector
                    let dragVector = world - dragStartWorld
                    let velocityScale: Float = 4.2  // calibrated for practical orbital insertion
                    let newVelocity = dragVector * velocityScale

                    for (i, b) in groupDragBodies.enumerated() {
                        b.isStatic = false
                        b.velocity = newVelocity
                    }
                } else {
                    // Normal drag mode: restore pre-drag velocities
                    for (i, b) in groupDragBodies.enumerated() {
                        b.isStatic = false
                        // Restore the velocity from before the drag started
                        if i < groupDragPreVelocities.count {
                            b.velocity = groupDragPreVelocities[i]
                        }
                    }
                }

                simulation.rebuildGPUState()
                isDragging       = false
                groupDragBodies  = []
                groupDragOffsets = []
                groupDragPreVelocities = []
                // Update table after drag completes to show final state
                updateTable()
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
            camera.scale = max(5, min(camera.scale * factor, 50000))
            return
        }
        // Scroll on selected bodies → change their spin
        let selected = simulation.bodies.filter { $0.isSelected }
        if !selected.isEmpty {
            let delta = Float(event.deltaX + event.deltaY) * 0.3
            selected.forEach { $0.angularVelocity += delta }
            simulation.rebuildGPUState()
            updateHUD()
            updateTable()
        }
        // Scroll wheel panning removed - use middle mouse button instead
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

    // MARK: - Middle mouse button panning

    override func otherMouseDown(with event: NSEvent) {
        // Middle mouse button (button number 2) starts panning
        if event.buttonNumber == 2 {
            isPanning = true
            panStartWorld = worldPoint(from: event)
            panStartCamera = camera.center
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if isPanning {
            let currentWorld = worldPoint(from: event)
            // Pan camera by the difference in world coordinates
            let delta = panStartWorld - currentWorld
            camera.center = panStartCamera + delta
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            isPanning = false
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // While a ship is being controlled, arrow keys steer it. Track the
        // pressed keys (autorepeat is fine — only the contains() matters in
        // applyShipControls). Suppress the system beep by returning early.
        if controlledShip != nil {
            switch event.keyCode {
            case 123, 124, 125, 126:
                arrowKeysHeld.insert(event.keyCode)
                return
            default:
                break
            }
        }
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
        case 9:                                     // V
            // Track V key for velocity drag mode (prevents system beep)
            isVKeyPressed = true
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if controlledShip != nil {
            switch event.keyCode {
            case 123, 124, 125, 126:
                arrowKeysHeld.remove(event.keyCode)
                return
            default:
                break
            }
        }
        switch event.keyCode {
        case 9:                                     // V
            isVKeyPressed = false
            // If we were dragging and V is released, restore pre-drag velocities
            if isDragging && !groupDragBodies.isEmpty {
                for (i, b) in groupDragBodies.enumerated() {
                    if i < groupDragPreVelocities.count {
                        b.velocity = groupDragPreVelocities[i]
                    }
                }
                simulation.rebuildGPUState()
                updateTable()
            }
        default:
            super.keyUp(with: event)
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

    // MARK: - Rosette configuration and placement

    private func showRosetteConfigDialog() {
        let alert = NSAlert()
        alert.messageText = "Keplerian Rosette Configuration"
        alert.informativeText = "Configure the rosette parameters"

        // Create the labels and fields
        let countLabel = NSTextField(labelWithString: "Number of bodies:")
        let countField = NSTextField(string: "\(rosetteCount)")
        countField.placeholderString = "6"

        let massLabel = NSTextField(labelWithString: "Mass per body:")
        let massField = NSTextField(string: "\(rosetteMass)")
        massField.placeholderString = "1.0"

        let radiusLabel = NSTextField(labelWithString: "Rosette radius:")
        let radiusField = NSTextField(string: "\(rosetteRadius)")
        radiusField.placeholderString = "300"

        let shapeLabel = NSTextField(labelWithString: "Body shape:")
        let shapePopup = NSPopUpButton()
        shapePopup.addItems(withTitles: ["Circle", "Rectangle", "Triangle"])
        shapePopup.selectItem(at: 0)

        // Wrap them in an NSGridView for perfect 2-column alignment
        let gridView = NSGridView(views: [
            [countLabel, countField],
            [massLabel, massField],
            [radiusLabel, radiusField],
            [shapeLabel, shapePopup]
        ])
        
        gridView.rowSpacing = 8
        gridView.columnSpacing = 10
        
        // Align labels to the right, and let inputs fill the remaining space
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .fill
        gridView.rowAlignment = .firstBaseline
        
        // FIX 1: Explicitly set the input column width natively
        gridView.column(at: 1).width = 80
        
        // FIX 2: Let the grid calculate its physical frame size,
        // removing the need for translatesAutoresizingMaskIntoConstraints = false
        gridView.setFrameSize(gridView.fittingSize)

        alert.accessoryView = gridView
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Parse values
            if let count = Int(countField.stringValue), count > 0 {
                rosetteCount = count
            }
            if let mass = Float(massField.stringValue), mass > 0 {
                rosetteMass = mass
            }
            if let radius = Float(radiusField.stringValue), radius > 0 {
                rosetteRadius = radius
            }

            // Set shape
            switch shapePopup.indexOfSelectedItem {
            case 0: rosetteShape = .circle(radius: 20)
            case 1: rosetteShape = .rectangle(width: 40, height: 30)
            case 2: rosetteShape = .triangle(radius: 25)
            default: rosetteShape = .circle(radius: 20)
            }

            // Enter rosette mode
            toolMode = .rosette
            simulation.deselectAll()
            updateToolButtons()
        }
    }

    private func addRosetteAt(_ center: SIMD2<Float>) {
        let G: Float = 800.0
        
        let N = rosetteCount
        guard N >= 2 else {
            // N=1 is not a rosette (no other bodies to provide gravity)
            return
        }
        
        // Compute the exact geometric factor C(N) for a regular N-gon of equal masses.
        // This is the standard closed-form expression for a Klemperer rosette:
        //   net inward acceleration on each body = (G * m / R²) * C(N)
        // where C(N) = (1/4) * Σ_{k=1}^{N-1} 1 / sin(π k / N)
        // (derived from vector sum of gravitational components; works for any N ≥ 2)
        var sum: Float = 0.0
        let piOverN = Float.pi / Float(N)
        for k in 1..<N {
            sum += 1.0 / sin(Float(k) * piOverN)
        }
        let C = sum / 4.0
        
        // Correct equilibrium orbital speed for the rosette (no central mass needed).
        // From force balance: v² / R = G * m * C / R²  ⇒  v = sqrt(G * m * C / R)
        // This is exact for equal-mass circular orbits around the common center of mass.
        let velocityMagnitude = sqrt(G * rosetteMass * C / rosetteRadius)
        
        for i in 0..<N {
            let angle = Float(i) * 2.0 * Float.pi / Float(N)
            let position = center + SIMD2<Float>(cos(angle), sin(angle)) * rosetteRadius
            
            // Tangential (perpendicular) velocity for counterclockwise rigid rotation
            let velocityDirection = SIMD2<Float>(-sin(angle), cos(angle))
            let velocity = velocityDirection * velocityMagnitude
            
            let color = bodyColors[colorIndex % bodyColors.count]
            colorIndex += 1
            
            let body = rosetteShape.makeBody(at: position, color: color)
            body.mass = rosetteMass
            body.velocity = velocity
            
            simulation.addBody(body)
        }
        
        updateHUD()
    }

    // MARK: - Galaxy configuration and placement

    private func showGalaxyConfigDialog() {
        let alert = NSAlert()
        alert.messageText = "Galaxy Configuration"
        alert.informativeText = "Configure the galaxy parameters"

        let countLabel = NSTextField(labelWithString: "Orbiting bodies:")
        let countField = NSTextField(string: "\(galaxyCount)")
        countField.placeholderString = "120"

        let radiusLabel = NSTextField(labelWithString: "Galaxy radius:")
        let radiusField = NSTextField(string: "\(galaxyRadius)")
        radiusField.placeholderString = "800"

        let compactCheckbox = NSButton(checkboxWithTitle: "Add central compact object", target: nil, action: nil)
        compactCheckbox.state = galaxyHasCentralMass ? .on : .off

        let gridView = NSGridView(views: [
            [countLabel, countField],
            [radiusLabel, radiusField],
            [compactCheckbox, NSView()]
        ])

        gridView.rowSpacing = 8
        gridView.columnSpacing = 10
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .fill
        gridView.rowAlignment = .firstBaseline
        gridView.column(at: 1).width = 100
        gridView.row(at: 2).mergeCells(in: NSRange(location: 0, length: 2))
        gridView.setFrameSize(gridView.fittingSize)

        alert.accessoryView = gridView
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let count = Int(countField.stringValue), count > 0 {
                galaxyCount = count
            }
            if let radius = Float(radiusField.stringValue), radius > 0 {
                galaxyRadius = radius
            }
            galaxyHasCentralMass = compactCheckbox.state == .on

            toolMode = .galaxy
            simulation.deselectAll()
            updateToolButtons()
        }
    }

    private func addGalaxyAt(_ center: SIMD2<Float>) {
        let G: Float = 800.0
        let maxBodies = 512
        let available = maxBodies - simulation.bodies.count
        guard available > 0 else { return }

        let includeCentral = galaxyHasCentralMass && available > 0
        let slotsForOrbiters = max(0, available - (includeCentral ? 1 : 0))
        let orbitingCount = min(galaxyCount, slotsForOrbiters)

        guard orbitingCount > 0 || includeCentral else { return }

        let radius = max(40.0, galaxyRadius)
        let period = max(4.0, min(20.0, galaxyTargetPeriod))

        // Choose masses so that an object near the outer edge completes an orbit in roughly the target period.
        let muTarget = (4 * Float.pi * Float.pi * pow(radius, 3)) / (period * period)
        let totalMassTarget = max(200.0, muTarget / G)

        let centralMass = includeCentral ? totalMassTarget * 0.65 : 0.0
        let orbitMassBudget = max(0.0, totalMassTarget - centralMass)
        let averageOrbitMass = orbitingCount > 0 ? max(0.5, orbitMassBudget / Float(orbitingCount)) : 0.0
        let totalOrbitMass = averageOrbitMass * Float(orbitingCount)

        if includeCentral {
            let compact = Body.makeCircle(
                position: center,
                radius: 1.0,
                color: SIMD4<Float>(1.0, 0.9, 0.6, 1.0),
                segments: 48
            )
            compact.mass = centralMass
            compact.momentOfInertia = Body.polygonMomentOfInertia(compact.localVertices, mass: compact.mass)
            simulation.addBody(compact)
        }

        for _ in 0..<orbitingCount {
            // Radial distribution biased toward the center for a dense core; sqrt keeps more mass inside.
            let radialFactor = sqrt(Float.random(in: 0.05...1.0))
            let r = radius * radialFactor
            let angle = Float.random(in: 0..<2 * Float.pi)
            let position = center + SIMD2<Float>(cos(angle), sin(angle)) * r

            // Assume the orbiting mass is roughly uniform with radius; add a central point mass if enabled.
            let enclosedMass = centralMass + totalOrbitMass * (r / radius)
            let velocityMagnitude = sqrt(max(0.0, (G * max(enclosedMass, 0.1)) / max(r, 8.0)))
            var velocity = SIMD2<Float>(-sin(angle), cos(angle)) * velocityMagnitude
            velocity *= 1 + Float.random(in: -0.06...0.06)  // small jitter to avoid perfect uniformity

            let color = bodyColors[colorIndex % bodyColors.count]
            colorIndex += 1

            let mass = averageOrbitMass
            let bodyRadius = max(4.0, min(18.0, sqrt(mass)))
            let body = Body.makeCircle(position: position, radius: bodyRadius, color: color)
            body.mass = mass
            body.momentOfInertia = Body.polygonMomentOfInertia(body.localVertices, mass: body.mass)
            body.velocity = velocity

            simulation.addBody(body)
        }

        updateHUD()
    }

    // MARK: - Ship configuration, placement, and control

    /// Computes a sensible default mass for a ship of the given length, based
    /// on the polygon area and the same density the regular `Body` initializer
    /// uses (1.0). Used to populate the dialog's mass field.
    private func defaultShipMass(forLength length: Float) -> Float {
        let probe = Body.makeShip(position: .zero,
                                  length: length,
                                  color: SIMD4<Float>(1, 1, 1, 1))
        return probe.mass
    }

    private func showShipConfigDialog() {
        let alert = NSAlert()
        alert.messageText = "Ship Configuration"
        alert.informativeText = "Configure the ship size and mass"

        let sizeLabel = NSTextField(labelWithString: "Ship size (length):")
        let sizeField = NSTextField(string: String(format: "%g", shipLength))
        sizeField.placeholderString = "26"

        // First-time defaulting: pick the area-derived mass for the current size.
        if shipMass <= 0 {
            shipMass = defaultShipMass(forLength: shipLength)
        }
        let massLabel = NSTextField(labelWithString: "Ship mass:")
        let massField = NSTextField(string: String(format: "%g", shipMass))
        massField.placeholderString = "\(defaultShipMass(forLength: shipLength))"

        let gridView = NSGridView(views: [
            [sizeLabel, sizeField],
            [massLabel, massField]
        ])
        gridView.rowSpacing = 8
        gridView.columnSpacing = 10
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .fill
        gridView.rowAlignment = .firstBaseline
        gridView.column(at: 1).width = 100
        gridView.setFrameSize(gridView.fittingSize)

        alert.accessoryView = gridView
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let len = Float(sizeField.stringValue), len > 0 {
                shipLength = len
            }
            if let m = Float(massField.stringValue), m > 0 {
                shipMass = m
            }
            toolMode = .ship
            simulation.deselectAll()
            updateToolButtons()
        }
    }

    private func addShipAt(_ position: SIMD2<Float>) {
        let color = bodyColors[colorIndex % bodyColors.count]
        colorIndex += 1
        let mass = shipMass > 0 ? shipMass : defaultShipMass(forLength: shipLength)
        let ship = Body.makeShip(position: position,
                                 length:   shipLength,
                                 mass:     mass,
                                 color:    color)
        simulation.addBody(ship)
        shipIDs.insert(ship.id)
        updateHUD()
    }

    // MARK: Ship-control floating panel & arrow-key control

    private func openShipControlPanel(for ship: Body) {
        controlledShip = ship

        if shipControlPanel == nil {
            let panel = ShipControlPanel(initialThrust: shipThrustValue)
            panel.title = "Ship Control"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.controllerDelegate = self
            // Position near the top-right of the main window.
            if let win = view.window {
                let origin = NSPoint(x: win.frame.maxX - panel.frame.width - 24,
                                     y: win.frame.maxY - panel.frame.height - 60)
                panel.setFrameOrigin(origin)
            }
            shipControlPanel = panel
        }
        // Make sure arrow-key state is fresh on (re)entry.
        arrowKeysHeld.removeAll()
        // Show but keep the main window key, so arrow keys still reach the
        // simulation view controller.
        shipControlPanel?.orderFront(nil)
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }

    fileprivate func shipControlPanelDidClose() {
        controlledShip = nil
        arrowKeysHeld.removeAll()
        shipControlPanel = nil
    }

    fileprivate func shipControlPanelThrustChanged(_ value: Float) {
        shipThrustValue = max(0, min(1, value))
    }

    fileprivate func shipControlPanelZeroVelocity() {
        controlledShip?.velocity = .zero
        simulation.rebuildGPUState()
        updateTable()
    }

    /// Called every physics step. If a ship is being controlled and arrow keys
    /// are held, applies thrust along the ship's facing direction and turning.
    private func applyShipControls() {
        guard let ship = controlledShip else { return }
        // If the controlled ship has been removed from the simulation, tear down.
        if !simulation.bodies.contains(where: { $0 === ship }) {
            shipControlPanel?.close()
            return
        }
        guard !arrowKeysHeld.isEmpty else { return }
        if simulation.isPaused { return }

        // Turning (constant rate, slider does not affect turn).
        if arrowKeysHeld.contains(123) {        // Left
            ship.angle += shipTurnPerStep
        }
        if arrowKeysHeld.contains(124) {        // Right
            ship.angle -= shipTurnPerStep
        }
        // Forward / reverse thrust scaled by slider.
        if shipThrustValue > 0 {
            let facing = SIMD2<Float>(cos(ship.angle), sin(ship.angle))
            let dv = facing * (shipThrustValue * shipMaxThrustPerStep)
            if arrowKeysHeld.contains(126) {    // Up — forward thrust
                ship.velocity += dv
            }
            if arrowKeysHeld.contains(125) {    // Down — reverse thrust
                ship.velocity -= dv
            }
        }
        simulation.rebuildGPUState()
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

// MARK: - NSSplitViewDelegate

extension SimulationViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if isRestoringSplitPosition {
            isRestoringSplitPosition = false
            return
        }
        renderer.viewSize = metalView.drawableSize
        simulation.rebuildGPUState()

        // While we're driving the divider programmatically (toggle / restore)
        // intermediate resize events must not be confused with a manual drag
        // and must not overwrite the persisted table width with the transient
        // collapsed state.
        if isProgrammaticallyAdjustingSplit {
            return
        }

        // Persist current table width (only saves when shown and > 0).
        saveTableWidth()

        // Keep showsTable in sync if the user manually drags the divider to collapse/expand the table pane
        let currentlyCollapsed = splitView.isSubviewCollapsed(tableScrollView)
        if showsTable == currentlyCollapsed {
            showsTable = !currentlyCollapsed
            saveTableVisibility()
            updateHUD()
        }
    }

    // Required for clean programmatic + user-driven collapse of the table pane (zero-width right pane)
    // without triggering legacy (non-AutoLayout) layout mode or runtime constraint errors.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return subview == tableScrollView
    }

    // Hide the divider when the table pane is collapsed (cleaner UI)
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return dividerIndex == 0 && splitView.isSubviewCollapsed(tableScrollView)
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

        // Focus column gets a checkbox
        if column.identifier.rawValue == "focus" {
            let checkIdentifier = NSUserInterfaceItemIdentifier("FocusCheckbox")
            var cell = tableView.makeView(withIdentifier: checkIdentifier, owner: self) as? NSTableCellView

            if cell == nil {
                cell = NSTableCellView()
                let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                cell?.addSubview(checkbox)
                cell?.identifier = checkIdentifier
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: cell!.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                ])
            }

            if let checkbox = cell?.subviews.first as? NSButton {
                checkbox.state = body.isFocused ? .on : .off
                checkbox.target = self
                checkbox.action = #selector(focusCheckboxToggled(_:))
                checkbox.tag = row
            }

            return cell
        }

        // Other columns get text fields
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
        textField.delegate = self

        // Determine if editable and set up appropriately
        let editableColumns = ["posX", "posY", "velX", "velY", "mass", "radius", "spin"]
        textField.isEditable = editableColumns.contains(column.identifier.rawValue)
        textField.isBordered = textField.isEditable
        textField.drawsBackground = textField.isEditable
        textField.backgroundColor = textField.isEditable ? NSColor.controlBackgroundColor : .clear
        textField.tag = row

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
            textField.stringValue = String(format: "%.3f", body.velocity.x)

        case "velY":
            textField.stringValue = String(format: "%.3f", body.velocity.y)

        case "mass":
            textField.stringValue = String(format: "%.1f", body.mass)

        case "radius":
            textField.stringValue = String(format: "%.1f", body.boundingRadius())

        case "spin":
            textField.stringValue = String(format: "%.2f", body.angularVelocity)

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

    @objc private func focusCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < simulation.bodies.count else { return }
        let body = simulation.bodies[row]

        if sender.state == .on {
            simulation.setFocused(body)
        } else {
            simulation.clearFocus()
        }

        simulation.rebuildGPUState()
        updateHUD()
        updateTable()
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

// MARK: - NSTextFieldDelegate for editable table cells

extension SimulationViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        let row = textField.tag
        guard row < simulation.bodies.count else { return }

        let body = simulation.bodies[row]
        let newValue = textField.stringValue
        guard let floatValue = Float(newValue) else { return }

        // Find which column by checking the table view
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
        for i in 0..<tableView.numberOfColumns {
            if let cellView = rowView.view(atColumn: i) as? NSTableCellView,
               cellView.textField == textField {
                let column = tableView.tableColumns[i]
                handleCellEdit(body: body, column: column.identifier.rawValue, value: floatValue)
                break
            }
        }
    }

    private func handleCellEdit(body: Body, column: String, value: Float) {
        switch column {
        case "posX":
            body.position.x = value
        case "posY":
            body.position.y = value
        case "velX":
            body.velocity.x = value
        case "velY":
            body.velocity.y = value
        case "mass":
            body.mass = max(value, 0.1)  // Ensure mass stays positive with a minimum value
            // Recalculate moment of inertia with new mass
            body.momentOfInertia = Body.polygonMomentOfInertia(body.localVertices, mass: body.mass)
        case "radius":
            // Scale all vertices to match new radius
            let currentRadius = body.boundingRadius()
            if currentRadius > 0 {
                let scale = value / currentRadius
                body.localVertices = body.localVertices.map { $0 * scale }
                // Recalculate moment of inertia with existing mass (mass should not change with radius)
                body.momentOfInertia = Body.polygonMomentOfInertia(body.localVertices, mass: body.mass)
                // Rebuild vertex buffer so the visual appearance updates
                simulation.rebuildVertexBuffer()
            }
        case "spin":
            body.angularVelocity = value
        default:
            return
        }

        // Update GPU state and refresh display
        simulation.rebuildGPUState()
        updateTable()
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

// MARK: - Ship-control floating panel

/// Floating panel that appears when a ship is double-clicked in select mode.
/// Hosts a thrust slider (0…1) and a "Velocity Zero" button. The panel is
/// designed to *not* steal key-window status from the main window so that
/// arrow-key input continues to reach the simulation view controller while
/// the panel is shown.
final class ShipControlPanel: NSPanel, NSWindowDelegate {

    weak var controllerDelegate: SimulationViewController?

    private let thrustSlider: NSSlider
    private let thrustLabel:  NSTextField
    private let zeroButton:   NSButton

    init(initialThrust: Float) {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        thrustSlider = NSSlider(value: Double(initialThrust),
                                minValue: 0.0,
                                maxValue: 1.0,
                                target: nil,
                                action: nil)
        thrustLabel = NSTextField(labelWithString: "Thrust:")
        zeroButton  = NSButton(title: "Velocity Zero", target: nil, action: nil)

        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
                   backing: .buffered,
                   defer: false)

        thrustLabel.textColor = .secondaryLabelColor
        thrustLabel.font = NSFont.systemFont(ofSize: 11)

        thrustSlider.isContinuous = true
        thrustSlider.target = self
        thrustSlider.action = #selector(thrustChanged(_:))
        thrustSlider.toolTip = "Thrust magnitude (↑/↓ apply forward/reverse thrust)"

        zeroButton.bezelStyle = .rounded
        zeroButton.target = self
        zeroButton.action = #selector(zeroVelocityClicked(_:))
        zeroButton.toolTip = "Set the controlled ship's velocity to zero"

        let row = NSStackView(views: [thrustLabel, thrustSlider, zeroButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        let helpField = NSTextField(labelWithString: "←/→ turn  ·  ↑/↓ thrust")
        helpField.textColor = .tertiaryLabelColor
        helpField.font = NSFont.systemFont(ofSize: 10)
        helpField.alignment = .center
        helpField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [row, helpField])
        column.orientation = .vertical
        column.spacing = 2
        column.alignment = .centerX
        column.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: frame)
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            thrustSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        self.contentView = content
        self.delegate = self
        self.isReleasedWhenClosed = false
    }

    @objc private func thrustChanged(_ sender: NSSlider) {
        controllerDelegate?.shipControlPanelThrustChanged(Float(sender.doubleValue))
    }

    @objc private func zeroVelocityClicked(_ sender: NSButton) {
        controllerDelegate?.shipControlPanelZeroVelocity()
    }

    // Keep main-window status with the simulation view; defer to
    // `becomesKeyOnlyIfNeeded` to grant key status only when a control
    // (e.g. slider drag) actually requires it.
    override var canBecomeMain: Bool { false }

    func windowWillClose(_ notification: Notification) {
        controllerDelegate?.shipControlPanelDidClose()
    }
}

