import Foundation
import Metal
import simd

// MARK: - Simulation parameters

private let kGravitationalConstant: Float = 800.0   // tuned so that v≈795 at r=380 gives stable ~3 s circular orbit with chosen masses
private let kSoftening:             Float = 0.0
private let kMaxBodies:             Int   = 512
private let kMaxVerticesPerBody:    Int   = 64
private let kMaxTotalVertices:      Int   = kMaxBodies * kMaxVerticesPerBody

struct SimParams {           // mirrors Metal struct
    var bodyCount:   UInt32
    var dt:          Float
    var G:           Float
    var softening:   Float
}

// MARK: - GravitySimulation

final class GravitySimulation {

    // MARK: Public state

    private(set) var bodies: [Body] = []
    var isPaused: Bool = false
    var currentTemplate: ShapeTemplate = .circle(radius: 30)
    var timeStep: Float = 1.0 / 60.0

    // MARK: Metal objects

    private let device:          MTLDevice
    private let commandQueue:    MTLCommandQueue
    private let computePipeline: MTLComputePipelineState

    /// Double-buffered body buffer (GPU writes, CPU reads)
    private var bodyBuffer:   [MTLBuffer]
    private var vertexBuffer: MTLBuffer      // local-space vertices for all bodies

    private var currentBufferIndex = 0

    // MARK: Callbacks

    var onUpdate: (() -> Void)?   // called each step so renderer can redraw

    // MARK: Init

    init(device: MTLDevice) throws {
        self.device       = device
        self.commandQueue = device.makeCommandQueue()!

        let library  = try device.makeDefaultLibrary(bundle: .main)
        let fn       = library.makeFunction(name: "physicsStep")!
        computePipeline = try device.makeComputePipelineState(function: fn)

        // Allocate double-buffered body buffer
        let bodySize = MemoryLayout<GPUBody>.stride * kMaxBodies
        bodyBuffer = (0..<2).map { _ in
            device.makeBuffer(length: bodySize, options: .storageModeShared)!
        }

        let vertexSize = MemoryLayout<SIMD2<Float>>.stride * kMaxTotalVertices
        vertexBuffer = device.makeBuffer(length: vertexSize, options: .storageModeShared)!
    }

    // MARK: - Body management

    func addBody(_ body: Body) {
        guard bodies.count < kMaxBodies else { return }
        bodies.append(body)
        rebuildVertexBuffer()
        onUpdate?()
    }

    func removeBody(_ body: Body) {
        bodies.removeAll { $0.id == body.id }
        rebuildVertexBuffer()
        onUpdate?()
    }

    func removeBodies(_ toRemove: [Body]) {
        let ids = Set(toRemove.map { $0.id })
        bodies.removeAll { ids.contains($0.id) }
        rebuildVertexBuffer()
        onUpdate?()
    }

    func removeSelectedBodies() {
        bodies.removeAll { $0.isSelected }
        rebuildVertexBuffer()
        onUpdate?()
    }

    func removeAllBodies() {
        bodies.removeAll()
        rebuildVertexBuffer()
        onUpdate?()
    }

    func selectAll() {
        bodies.forEach { $0.isSelected = true }
    }

    func deselectAll() {
        bodies.forEach { $0.isSelected = false }
    }

    func setFocused(_ body: Body) {
        // Only one body can be focused at a time
        bodies.forEach { $0.isFocused = false }
        body.isFocused = true
    }

    func clearFocus() {
        bodies.forEach { $0.isFocused = false }
    }

    var focusedBody: Body? {
        bodies.first { $0.isFocused }
    }

    /// Returns the first body that contains the given world-space point.
    func body(at point: SIMD2<Float>) -> Body? {
        bodies.reversed().first { $0.contains(point: point) }
    }

    /// Returns all bodies whose world-space bounding box overlaps a rectangle.
    func bodies(inRect rect: CGRect) -> [Body] {
        bodies.filter { b in
            let p = CGPoint(x: Double(b.position.x), y: Double(b.position.y))
            let r = CGFloat(b.boundingRadius())
            return rect.intersects(CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                && b.worldVertices().contains { v in
                    rect.contains(CGPoint(x: Double(v.x), y: Double(v.y)))
                }
        }
    }

    /// Returns all bodies contained within an arbitrary lasso polygon (world space).
    func bodies(inLasso lasso: [SIMD2<Float>]) -> [Body] {
        guard lasso.count >= 3 else { return [] }
        return bodies.filter { b in
            b.worldVertices().contains { v in pointInPolygon(v, polygon: lasso) }
        }
    }

    // MARK: - Physics step (Metal compute)

    func step() {
        guard !isPaused, !bodies.isEmpty else { return }

        let writeIdx = 1 - currentBufferIndex

        var params = SimParams(
            bodyCount: UInt32(bodies.count),
            dt:        timeStep,
            G:         kGravitationalConstant,
            softening: kSoftening
        )

        guard let cmdBuf   = commandQueue.makeCommandBuffer(),
              let encoder  = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(computePipeline)
        // Double buffering: read from current buffer (which has latest CPU state),
        // write to the other buffer with physics results.
        encoder.setBuffer(bodyBuffer[currentBufferIndex], offset: 0, index: 0) // input
        encoder.setBuffer(bodyBuffer[writeIdx],           offset: 0, index: 1) // output
        encoder.setBytes(&params, length: MemoryLayout<SimParams>.size, index: 2)
        encoder.setBuffer(vertexBuffer, offset: 0, index: 3) // vertex buffer for collision detection

        let threadCount = MTLSize(width: bodies.count, height: 1, depth: 1)
        let threadGroupSize = MTLSize(
            width: min(computePipeline.maxTotalThreadsPerThreadgroup, bodies.count),
            height: 1, depth: 1
        )
        encoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        cmdBuf.addCompletedHandler { [weak self] _ in
            // Download physics results and switch buffer index on main queue for perfect sync.
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.downloadBodies(from: writeIdx)
                self.currentBufferIndex = writeIdx
                // After downloading and switching, upload the CPU state to the new current buffer
                // so it's in sync and ready for the next step or render
                self.uploadBodies(to: writeIdx)
                self.onUpdate?()
            }
        }
        cmdBuf.commit()
    }

    // MARK: - Buffer accessors for renderer

    /// Current body GPU buffer (for renderer to bind).
    var currentBodyBuffer: MTLBuffer { bodyBuffer[currentBufferIndex] }

    /// Vertex buffer (shared vertex data for all bodies).
    var sharedVertexBuffer: MTLBuffer { vertexBuffer }

    // MARK: - Public GPU state refresh

    /// Re-uploads the current body data to the current GPU buffer without running physics.
    /// Call after modifying bodies' positions/velocities/selection directly (e.g., during a drag).
    /// Only uploads to currentBufferIndex; the next physics step will read from it and
    /// write updated data to the other buffer, naturally keeping both buffers in sync.
    func rebuildGPUState() {
        uploadBodies(to: currentBufferIndex)
    }

    // MARK: - Private helpers

    private func rebuildVertexBuffer() {
        var offset = 0
        let ptr = vertexBuffer.contents().bindMemory(to: SIMD2<Float>.self,
                                                     capacity: kMaxTotalVertices)
        for body in bodies {
            body.vertexOffset = offset
            for v in body.localVertices {
                guard offset < kMaxTotalVertices else { break }
                ptr[offset] = v
                offset += 1
            }
        }
        // Re-upload body buffer to BOTH buffers so vertex offsets are current in both.
        // This is critical because the vertex buffer is shared, and double-buffering
        // the body data means both buffers need consistent vertex offset information.
        uploadBodies(to: 0)
        uploadBodies(to: 1)
    }

    func uploadBodies(to index: Int) {
        let ptr = bodyBuffer[index].contents().bindMemory(to: GPUBody.self, capacity: kMaxBodies)
        for (i, body) in bodies.enumerated() {
            ptr[i] = body.toGPU()
        }
    }

    private func downloadBodies(from index: Int) {
        let ptr = bodyBuffer[index].contents().bindMemory(to: GPUBody.self, capacity: kMaxBodies)
        for (i, body) in bodies.enumerated() {
            guard i < kMaxBodies else { break }
            let g = ptr[i]
            body.position        = SIMD2<Float>(g.posX, g.posY)
            body.velocity        = SIMD2<Float>(g.velX, g.velY)
            body.angle           = g.angle
            body.angularVelocity = g.angularVel
        }
    }

    // MARK: - Pre-built demo scene

    func loadDemoScene() {
        bodies.removeAll()

        // Heavy central sphere (yellow-ish)
        let central = Body.makeCircle(
            position: .zero,
            radius: 48,
            color: SIMD4<Float>(1.0, 0.88, 0.45, 1.0),
            segments: 48
        )
        central.mass *= 40
        central.isFocused = true  // Focus on central object by default
        addBody(central)

        // Lighter orbiting triangle (blue-cyan)
        let triangle = Body.makeTriangle(
            position: SIMD2<Float>(380, 0),
            radius: 26,
            color: SIMD4<Float>(0.35, 0.75, 1.0, 1.0)
        )
        triangle.velocity = SIMD2<Float>(0, 795)   // produces one orbit per ~3 s with the tuned G, dt, and central mass
        triangle.angularVelocity = 5.0
        addBody(triangle)
    }
}
