import Metal
import MetalKit
import simd

// MARK: - Camera

struct Camera {
    var center: SIMD2<Float> = .zero   // world-space point at screen center
    var scale:  Float = 300.0          // world-units per NDC unit (half-screen)

    func worldToNDC(_ worldPos: SIMD2<Float>, aspectRatio: Float) -> SIMD2<Float> {
        let offset = (worldPos - center) / scale
        return SIMD2<Float>(offset.x, offset.y * aspectRatio)
    }

    func ndcToWorld(_ ndc: SIMD2<Float>, aspectRatio: Float) -> SIMD2<Float> {
        center + SIMD2<Float>(ndc.x * scale, ndc.y / aspectRatio * scale)
    }

    /// Convert AppKit NSPoint (pixels, origin bottom-left in view space) → world-space.
    func viewToWorld(_ point: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        let nx = Float(point.x / viewSize.width  * 2 - 1)
        let ny = Float(point.y / viewSize.height * 2 - 1)   // y is already bottom-up in Metal view
        let ar = Float(viewSize.width / max(viewSize.height, 1))
        return ndcToWorld(SIMD2<Float>(nx, ny), aspectRatio: ar)
    }
}

// MARK: - RenderUniforms (matches Metal struct)

struct RenderUniforms {
    var cameraCenter: SIMD2<Float>
    var cameraScale:  Float
    var aspectRatio:  Float
}

// MARK: - MetalRenderer

final class MetalRenderer: NSObject, MTKViewDelegate {

    // MARK: Dependencies

    weak var simulation: GravitySimulation?
    var camera = Camera()

    // MARK: Metal state

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var bodyRenderPipeline:    MTLRenderPipelineState!
    private var outlineRenderPipeline: MTLRenderPipelineState!
    private var uiRenderPipeline:      MTLRenderPipelineState!

    // Per-body index buffer cache (triangle list, filled polygon)
    private var indexBufferCache: [UUID: (buffer: MTLBuffer, count: Int)] = [:]

    var viewSize: CGSize = CGSize(width: 1, height: 1)

    // MARK: Overlay drawing data (set by SimulationViewController each frame)

    struct SelectionOverlay {
        enum Kind { case none, rect(CGRect), lasso([CGPoint]) }
        var kind:     Kind  = .none
        var isActive: Bool  = false
    }
    var selectionOverlay = SelectionOverlay()

    // MARK: Init

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device       = device
        self.commandQueue = device.makeCommandQueue()!
        super.init()
        try buildPipelines(pixelFormat: pixelFormat)
    }

    // MARK: - Index buffer helpers

    private func indexBuffer(for body: Body) -> (buffer: MTLBuffer, count: Int)? {
        if let cached = indexBufferCache[body.id] { return cached }
        let tris = body.triangleIndices
        guard !tris.isEmpty else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(tris.count * 3)
        for t in tris { indices.append(contentsOf: [UInt32(t.0), UInt32(t.1), UInt32(t.2)]) }
        guard let buf = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt32>.stride * indices.count,
            options: .storageModeShared) else { return nil }
        let entry = (buffer: buf, count: indices.count)
        indexBufferCache[body.id] = entry
        return entry
    }

    func evictIndexBuffer(for bodyID: UUID) {
        indexBufferCache.removeValue(forKey: bodyID)
    }

    // MARK: - Pipeline setup

    private func buildPipelines(pixelFormat: MTLPixelFormat) throws {
        let library = try device.makeDefaultLibrary(bundle: .main)

        // Body fill pipeline
        let bodyDesc = MTLRenderPipelineDescriptor()
        bodyDesc.vertexFunction   = library.makeFunction(name: "bodyVert")
        bodyDesc.fragmentFunction = library.makeFunction(name: "bodyFrag")
        bodyDesc.colorAttachments[0].pixelFormat = pixelFormat
        bodyDesc.colorAttachments[0].isBlendingEnabled = true
        bodyDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bodyDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bodyRenderPipeline = try device.makeRenderPipelineState(descriptor: bodyDesc)

        // Outline pipeline (line strip)
        let outlineDesc = MTLRenderPipelineDescriptor()
        outlineDesc.vertexFunction   = library.makeFunction(name: "outlineVert")
        outlineDesc.fragmentFunction = library.makeFunction(name: "outlineFrag")
        outlineDesc.colorAttachments[0].pixelFormat = pixelFormat
        outlineRenderPipeline = try device.makeRenderPipelineState(descriptor: outlineDesc)

        // UI overlay pipeline
        let uiDesc = MTLRenderPipelineDescriptor()
        uiDesc.vertexFunction   = library.makeFunction(name: "uiVert")
        uiDesc.fragmentFunction = library.makeFunction(name: "uiFrag")
        uiDesc.colorAttachments[0].pixelFormat = pixelFormat
        uiDesc.colorAttachments[0].isBlendingEnabled = true
        uiDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        uiDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        uiRenderPipeline = try device.makeRenderPipelineState(descriptor: uiDesc)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = size
    }

    func draw(in view: MTKView) {
        guard let sim = simulation,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmdBuf   = commandQueue.makeCommandBuffer() else { return }

        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1)
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].storeAction = .store

        guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let ar = Float(viewSize.width / max(viewSize.height, 1))
        var uniforms = RenderUniforms(
            cameraCenter: camera.center,
            cameraScale:  camera.scale,
            aspectRatio:  ar
        )

        let bodyBuffer   = sim.currentBodyBuffer
        let vertexBuffer = sim.sharedVertexBuffer

        // ── Draw each body (filled polygon via triangle list) ──────────────

        encoder.setRenderPipelineState(bodyRenderPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(bodyBuffer,   offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.size, index: 2)

        for (i, body) in sim.bodies.enumerated() {
            var idx = Int32(i)
            encoder.setVertexBytes(&idx, length: MemoryLayout<Int32>.size, index: 3)
            if let (ibuf, count) = indexBuffer(for: body) {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: count,
                    indexType: .uint32,
                    indexBuffer: ibuf,
                    indexBufferOffset: 0)
            }
        }

        // ── Draw outlines for selected bodies ─────────────────────────────

        encoder.setRenderPipelineState(outlineRenderPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(bodyBuffer,   offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.size, index: 2)

        for (i, body) in sim.bodies.enumerated() where body.isSelected {
            var idx = Int32(i)
            encoder.setVertexBytes(&idx, length: MemoryLayout<Int32>.size, index: 3)
            // Draw N+1 vertices; outlineVert wraps with vid % vertexCount to close the loop.
            let count = body.localVertices.count + 1
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: count)
        }

        // ── Draw UI overlay (selection rectangle or lasso) ────────────────

        drawOverlay(encoder: encoder, uniforms: uniforms)

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Overlay

    private func drawOverlay(encoder: MTLRenderCommandEncoder, uniforms: RenderUniforms) {
        guard selectionOverlay.isActive else { return }
        encoder.setRenderPipelineState(uiRenderPipeline)

        let ar = uniforms.aspectRatio

        switch selectionOverlay.kind {
        case .none: break

        case .rect(let r):
            let tl = worldToNDC(SIMD2<Float>(Float(r.minX), Float(r.maxY)), uniforms: uniforms, ar: ar)
            let br = worldToNDC(SIMD2<Float>(Float(r.maxX), Float(r.minY)), uniforms: uniforms, ar: ar)
            // Filled semi-transparent rectangle (2 triangles)
            let filled: [SIMD2<Float>] = [
                SIMD2(tl.x, tl.y), SIMD2(br.x, tl.y), SIMD2(br.x, br.y),
                SIMD2(tl.x, tl.y), SIMD2(br.x, br.y), SIMD2(tl.x, br.y)
            ]
            var fillColor = SIMD4<Float>(0.3, 0.7, 1.0, 0.2)
            drawUIVerts(filled, type: .triangle, color: &fillColor, encoder: encoder)
            // Outline
            let outline: [SIMD2<Float>] = [
                SIMD2(tl.x, tl.y), SIMD2(br.x, tl.y),
                SIMD2(br.x, br.y), SIMD2(tl.x, br.y), SIMD2(tl.x, tl.y)
            ]
            var lineColor = SIMD4<Float>(0.3, 0.8, 1.0, 0.9)
            drawUIVerts(outline, type: .lineStrip, color: &lineColor, encoder: encoder)

        case .lasso(let pts):
            guard pts.count >= 2 else { return }
            let ndcPts = pts.map { p -> SIMD2<Float> in
                let wp = SIMD2<Float>(Float(p.x), Float(p.y))
                return worldToNDC(wp, uniforms: uniforms, ar: ar)
            }
            var lineColor = SIMD4<Float>(1.0, 0.9, 0.2, 0.9)
            drawUIVerts(ndcPts, type: .lineStrip, color: &lineColor, encoder: encoder)
        }
    }

    private func worldToNDC(_ w: SIMD2<Float>, uniforms: RenderUniforms, ar: Float) -> SIMD2<Float> {
        let offset = (w - uniforms.cameraCenter) / uniforms.cameraScale
        return SIMD2<Float>(offset.x, offset.y * ar)
    }

    private func drawUIVerts(
        _ verts: [SIMD2<Float>],
        type: MTLPrimitiveType,
        color: inout SIMD4<Float>,
        encoder: MTLRenderCommandEncoder
    ) {
        guard !verts.isEmpty else { return }
        guard let buf = device.makeBuffer(
            bytes: verts,
            length: MemoryLayout<SIMD2<Float>>.stride * verts.count,
            options: .storageModeShared) else { return }
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&color, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.drawPrimitives(type: type, vertexStart: 0, vertexCount: verts.count)
    }
}

// MARK: - Body extension: triangulation cache

extension Body {
    /// Pre-computed triangle index triples for the body's local polygon.
    var triangleIndices: [(Int, Int, Int)] {
        if _triangleCache == nil { _triangleCache = buildTriangles() }
        return _triangleCache!
    }

    private static var _caches: [ObjectIdentifier: [(Int, Int, Int)]] = [:]

    private var _triangleCache: [(Int, Int, Int)]? {
        get { Body._caches[ObjectIdentifier(self)] }
        set { Body._caches[ObjectIdentifier(self)] = newValue }
    }

    private func buildTriangles() -> [(Int, Int, Int)] {
        let idxFlat = earClipTriangulate(localVertices)
        var result: [(Int, Int, Int)] = []
        var k = 0
        while k + 2 < idxFlat.count {
            result.append((idxFlat[k], idxFlat[k+1], idxFlat[k+2]))
            k += 3
        }
        return result
    }

    func invalidateTriangleCache() {
        Body._caches.removeValue(forKey: ObjectIdentifier(self))
    }
}


// MARK: - RenderUniforms (matches Metal struct)
