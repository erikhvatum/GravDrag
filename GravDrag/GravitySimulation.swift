import Foundation
import Metal
import simd

// MARK: - Simulation parameters

private let kGravitationalConstant: Float = 6.674e-4  // scaled for visibility
private let kSoftening:             Float = 20.0       // pixels, prevents singularity
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
    }

    func removeBody(_ body: Body) {
        bodies.removeAll { $0.id == body.id }
        rebuildVertexBuffer()
    }

    func removeBodies(_ toRemove: [Body]) {
        let ids = Set(toRemove.map { $0.id })
        bodies.removeAll { ids.contains($0.id) }
        rebuildVertexBuffer()
    }

    func removeSelectedBodies() {
        bodies.removeAll { $0.isSelected }
        rebuildVertexBuffer()
    }

    func selectAll() {
        bodies.forEach { $0.isSelected = true }
    }

    func deselectAll() {
        bodies.forEach { $0.isSelected = false }
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
        uploadBodies(to: writeIdx)

        var params = SimParams(
            bodyCount: UInt32(bodies.count),
            dt:        timeStep,
            G:         kGravitationalConstant,
            softening: kSoftening
        )

        guard let cmdBuf   = commandQueue.makeCommandBuffer(),
              let encoder  = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(bodyBuffer[writeIdx], offset: 0, index: 0)
        encoder.setBuffer(vertexBuffer,         offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<SimParams>.size, index: 2)

        let threadCount = MTLSize(width: bodies.count, height: 1, depth: 1)
        let threadGroupSize = MTLSize(
            width: min(computePipeline.maxTotalThreadsPerThreadgroup, bodies.count),
            height: 1, depth: 1
        )
        encoder.dispatchThreads(threadCount, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        cmdBuf.addCompletedHandler { [weak self] _ in
            self?.downloadBodies(from: writeIdx)
            self?.currentBufferIndex = writeIdx
            self?.onUpdate?()
        }
        cmdBuf.commit()
    }

    // MARK: - Buffer accessors for renderer

    /// Current body GPU buffer (for renderer to bind).
    var currentBodyBuffer: MTLBuffer { bodyBuffer[currentBufferIndex] }

    /// Vertex buffer (shared vertex data for all bodies).
    var sharedVertexBuffer: MTLBuffer { vertexBuffer }

    // MARK: - Public GPU state refresh

    /// Re-uploads the current body data to the GPU buffer without running physics.
    /// Call after modifying bodies' positions/velocities directly (e.g., during a drag).
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
        // Re-upload body buffer so offsets are current
        uploadBodies(to: currentBufferIndex)
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
        let colors: [SIMD4<Float>] = [
            SIMD4<Float>(0.9, 0.4, 0.3, 1),
            SIMD4<Float>(0.4, 0.8, 0.5, 1),
            SIMD4<Float>(0.4, 0.6, 1.0, 1),
            SIMD4<Float>(1.0, 0.8, 0.3, 1),
            SIMD4<Float>(0.8, 0.4, 0.9, 1),
        ]
        let positions: [(Float, Float, Float, Float)] = [
            // x,    y,    vx,   vy
            ( 0,    200,  120,   0),
            ( 0,   -200, -120,   0),
            ( 200,   0,    0,  120),
            (-200,   0,    0, -120),
        ]
        for (i, pos) in positions.enumerated() {
            let b = Body.makeCircle(
                position: SIMD2<Float>(pos.0, pos.1),
                radius: 20 + Float(i) * 5,
                color: colors[i % colors.count]
            )
            b.velocity = SIMD2<Float>(pos.2, pos.3)
            addBody(b)
        }
        // Heavier central body
        let central = Body.makeCircle(
            position: .zero,
            radius: 45,
            color: SIMD4<Float>(1.0, 0.9, 0.5, 1)
        )
        central.mass *= 10
        addBody(central)
    }
}
