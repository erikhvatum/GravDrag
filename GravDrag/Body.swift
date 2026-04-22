import Foundation
import simd

// MARK: - GPU-compatible body struct (must exactly mirror Metal shader struct)

struct GPUBody {
    var posX:             Float   // world x
    var posY:             Float   // world y
    var velX:             Float
    var velY:             Float
    var radius:           Float   // bounding radius
    var angle:            Float   // radians
    var angularVel:       Float   // rad/s
    var mass:             Float
    var momentOfInertia:  Float
    var vertexOffset:     Int32   // index into global vertex buffer
    var vertexCount:      Int32
    var colorR:           Float
    var colorG:           Float
    var colorB:           Float
    var colorA:           Float
    var isStatic:         Int32   // 1 = fixed
    var isSelected:       Int32   // 1 = selected (used by renderer)
    var isFocused:        Int32   // 1 = focused (camera follows)
    var _padding:         Int32   // padding to maintain alignment
    var _padding2:        Float   // pad to 80 bytes to match Metal struct alignment
    // Total: 80 bytes (alignment 8, cache-friendly)
}

// MARK: - Swift-side Body

final class Body: Identifiable {
    let id = UUID()

    var position:        SIMD2<Float>
    var velocity:        SIMD2<Float>
    var angle:           Float
    var angularVelocity: Float
    var mass:            Float
    var momentOfInertia: Float
    /// Vertices in local (body) space, with centroid at origin.
    var localVertices:   [SIMD2<Float>] {
        didSet { invalidateTriangleCache() }
    }
    var color:           SIMD4<Float>
    var isStatic:        Bool
    var isSelected:      Bool = false
    var isFocused:       Bool = false

    // Cache for GPU upload
    var vertexOffset: Int = 0   // set by GravitySimulation when building vertex buffer
    
    deinit {
        invalidateTriangleCache()
    }

    init(
        position:      SIMD2<Float>,
        velocity:      SIMD2<Float>   = .zero,
        angle:         Float           = 0,
        angularVelocity: Float         = 0,
        localVertices: [SIMD2<Float>],
        color:         SIMD4<Float>,
        isStatic:      Bool            = false
    ) {
        self.position        = position
        self.velocity        = velocity
        self.angle           = angle
        self.angularVelocity = angularVelocity
        self.localVertices   = localVertices
        self.color           = color
        self.isStatic        = isStatic

        let area = Body.polygonArea(localVertices)
        let density: Float = 1.0
        self.mass            = max(area * density, 0.5)
        self.momentOfInertia = Body.polygonMomentOfInertia(localVertices, mass: self.mass)
    }

    // MARK: - Factory helpers

    static func makeCircle(
        position: SIMD2<Float>,
        radius: Float,
        color: SIMD4<Float>,
        segments: Int = 32
    ) -> Body {
        let verts = (0..<segments).map { i -> SIMD2<Float> in
            let a = Float(i) / Float(segments) * 2 * Float.pi
            return SIMD2<Float>(cos(a) * radius, sin(a) * radius)
        }
        return Body(position: position, localVertices: verts, color: color)
    }

    static func makeRect(
        position: SIMD2<Float>,
        width: Float,
        height: Float,
        color: SIMD4<Float>
    ) -> Body {
        let hw = width / 2, hh = height / 2
        let verts: [SIMD2<Float>] = [
            SIMD2<Float>(-hw, -hh),
            SIMD2<Float>( hw, -hh),
            SIMD2<Float>( hw,  hh),
            SIMD2<Float>(-hw,  hh)
        ]
        return Body(position: position, localVertices: verts, color: color)
    }

    static func makeTriangle(
        position: SIMD2<Float>,
        radius: Float,
        color: SIMD4<Float>
    ) -> Body {
        let verts: [SIMD2<Float>] = (0..<3).map { i -> SIMD2<Float> in
            let a = Float(i) / 3.0 * 2 * Float.pi - Float.pi / 2
            return SIMD2<Float>(cos(a) * radius, sin(a) * radius)
        }
        return Body(position: position, localVertices: verts, color: color)
    }

    // MARK: - Geometry helpers

    static func polygonArea(_ verts: [SIMD2<Float>]) -> Float {
        guard verts.count >= 3 else { return 1 }
        var area: Float = 0
        let n = verts.count
        for i in 0..<n {
            let j = (i + 1) % n
            area += verts[i].x * verts[j].y
            area -= verts[j].x * verts[i].y
        }
        return abs(area) * 0.5
    }

    static func polygonMomentOfInertia(_ verts: [SIMD2<Float>], mass: Float) -> Float {
        guard verts.count >= 3 else { return mass }
        var num: Float = 0
        var den: Float = 0
        let n = verts.count
        for i in 0..<n {
            let j = (i + 1) % n
            let cross = abs(verts[i].x * verts[j].y - verts[j].x * verts[i].y)
            num += cross * (simd_dot(verts[i], verts[i]) +
                            simd_dot(verts[i], verts[j]) +
                            simd_dot(verts[j], verts[j]))
            den += cross
        }
        guard den > 0 else { return mass }
        return (mass / 6.0) * (num / den)
    }

    func worldVertices() -> [SIMD2<Float>] {
        let c = cos(angle), s = sin(angle)
        return localVertices.map { v in
            SIMD2<Float>(position.x + v.x * c - v.y * s,
                         position.y + v.x * s + v.y * c)
        }
    }

    func boundingRadius() -> Float {
        localVertices.map { simd_length($0) }.max() ?? 1
    }

    func contains(point p: SIMD2<Float>) -> Bool {
        pointInPolygon(p, polygon: worldVertices())
    }

    func toGPU() -> GPUBody {
        GPUBody(
            posX:            position.x,
            posY:            position.y,
            velX:            velocity.x,
            velY:            velocity.y,
            radius:          boundingRadius(),
            angle:           angle,
            angularVel:      angularVelocity,
            mass:            mass,
            momentOfInertia: momentOfInertia,
            vertexOffset:    Int32(vertexOffset),
            vertexCount:     Int32(localVertices.count),
            colorR:          color.x,
            colorG:          color.y,
            colorB:          color.z,
            colorA:          color.w,
            isStatic:        isStatic  ? 1 : 0,
            isSelected:      isSelected ? 1 : 0,
            isFocused:       isFocused ? 1 : 0,
            _padding:        0,
            _padding2:       0
        )
    }
}

// MARK: - Point-in-polygon (ray casting)

func pointInPolygon(_ p: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
    var inside = false
    let n = polygon.count
    var j = n - 1
    for i in 0..<n {
        let xi = polygon[i].x, yi = polygon[i].y
        let xj = polygon[j].x, yj = polygon[j].y
        let cond = ((yi > p.y) != (yj > p.y)) &&
                   (p.x < (xj - xi) * (p.y - yi) / (yj - yi) + xi)
        if cond { inside = !inside }
        j = i
    }
    return inside
}

// MARK: - Ear-clip triangulation (for irregular polygons, CPU-side)
// Returns flat array of vertex indices (groups of 3).

func earClipTriangulate(_ polygon: [SIMD2<Float>]) -> [Int] {
    guard polygon.count >= 3 else { return [] }
    if polygon.count == 3 { return [0, 1, 2] }

    var indices = Array(0..<polygon.count)
    var result: [Int] = []

    func isEar(i: Int) -> Bool {
        let n = indices.count
        let prev = indices[(i + n - 1) % n]
        let curr = indices[i]
        let next = indices[(i + 1) % n]
        // Check triangle is CCW (positive area)
        let a = polygon[prev], b = polygon[curr], c = polygon[next]
        let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        if cross <= 0 { return false }
        // Check no other vertices inside the triangle
        for k in 0..<n where k != (i + n - 1) % n && k != i && k != (i + 1) % n {
            if pointInTriangle(polygon[indices[k]], a: a, b: b, c: c) { return false }
        }
        return true
    }

    var remaining = indices.count
    var attempts = 0
    var i = 0
    while remaining > 3 {
        if isEar(i: i % remaining) {
            let n = remaining
            let prev = indices[(i % n + n - 1) % n]
            let curr = indices[i % n]
            let next = indices[(i % n + 1) % n]
            result.append(contentsOf: [prev, curr, next])
            indices.remove(at: i % n)
            remaining -= 1
            attempts = 0
        } else {
            i += 1
            attempts += 1
            if attempts > remaining { break }  // degenerate polygon
        }
    }
    if remaining == 3 {
        result.append(contentsOf: [indices[0], indices[1], indices[2]])
    }
    return result
}

func pointInTriangle(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>) -> Bool {
    func sign(_ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>) -> Float {
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }
    let d1 = sign(p, a, b), d2 = sign(p, b, c), d3 = sign(p, c, a)
    let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
    let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
    return !(hasNeg && hasPos)
}

// MARK: - Predefined shape templates

enum ShapeTemplate {
    case circle(radius: Float)
    case rectangle(width: Float, height: Float)
    case triangle(radius: Float)
    case custom(vertices: [SIMD2<Float>])

    func makeBody(at position: SIMD2<Float>, color: SIMD4<Float>) -> Body {
        switch self {
        case .circle(let r):   return Body.makeCircle(position: position, radius: r, color: color)
        case .rectangle(let w, let h): return Body.makeRect(position: position, width: w, height: h, color: color)
        case .triangle(let r): return Body.makeTriangle(position: position, radius: r, color: color)
        case .custom(let verts):
            guard verts.count >= 3 else {
                return Body.makeCircle(position: position, radius: 30, color: color)
            }
            return Body(position: position, localVertices: verts, color: color)
        }
    }
}
