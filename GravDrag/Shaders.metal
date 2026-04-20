#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────
// Shared types (must exactly mirror Swift GPUBody struct)
// ─────────────────────────────────────────────────────────

struct Body {
    float2 position;        // 8
    float2 velocity;        // 8
    float  angle;           // 4
    float  angularVel;      // 4
    float  mass;            // 4
    float  momentOfInertia; // 4
    int    vertexOffset;    // 4
    int    vertexCount;     // 4
    float4 color;           // 16
    int    isStatic;        // 4
    int    isSelected;      // 4
    int    isFocused;       // 4
    int    _padding;        // 4
    // 72 bytes total
};

struct SimParams {
    uint  bodyCount;
    float dt;
    float G;
    float softening;  // prevents singularity at r→0
};

struct RenderUniforms {
    float2 cameraCenter; // world-space position at screen center
    float  cameraScale;  // world-units per NDC unit (half-screen)
    float  aspectRatio;  // width / height
};

// ─────────────────────────────────────────────────────────
// Compute: N-body gravity + semi-implicit Euler integration + elastic collisions
// Now uses separate input/output buffers to eliminate all races.
// ─────────────────────────────────────────────────────────

// Helper: compute bounding radius from vertex data
float computeBoundingRadius(constant float2* vertices, int offset, int count) {
    float maxDist = 0.0f;
    for (int i = 0; i < count; i++) {
        float2 v = vertices[offset + i];
        float dist = length(v);
        maxDist = max(maxDist, dist);
    }
    return maxDist;
}

// Helper: check if two circles collide and resolve with elastic collision
bool resolveCircleCollision(thread Body& self, Body other, float selfRadius, float otherRadius) {
    float2 diff = other.position - self.position;
    float dist = length(diff);
    float minDist = selfRadius + otherRadius;

    if (dist < minDist && dist > 0.001f) {
        // Collision detected
        float2 normal = diff / dist;

        // Separate the bodies (move self away from other)
        float overlap = minDist - dist;
        self.position -= normal * (overlap * 0.5f);

        // Elastic collision response (100% elasticity, conserve momentum and energy)
        // Relative velocity
        float2 relVel = self.velocity - other.velocity;
        float velAlongNormal = dot(relVel, normal);

        // Don't resolve if velocities are separating
        if (velAlongNormal > 0.0f) return true;

        // Calculate impulse scalar (perfectly elastic: restitution = 1.0)
        float impulse = -(2.0f * velAlongNormal) / (1.0f / self.mass + 1.0f / other.mass);

        // Apply impulse to self (other body handled in its own thread)
        float2 impulseVec = impulse * normal / self.mass;
        self.velocity += impulseVec;

        return true;
    }
    return false;
}

kernel void physicsStep(
    constant Body* inputBodies   [[ buffer(0) ]],
    device Body*   outputBodies  [[ buffer(1) ]],
    constant SimParams& params   [[ buffer(2) ]],
    constant float2* vertices    [[ buffer(3) ]],
    uint id [[ thread_position_in_grid ]])
{
    if (id >= params.bodyCount) return;

    Body self = inputBodies[id];
    if (self.isStatic) {
        outputBodies[id] = self;
        return;
    }

    // Compute bounding radius for collision detection
    float selfRadius = computeBoundingRadius(vertices, self.vertexOffset, self.vertexCount);

    float2 force = float2(0.0f, 0.0f);

    // Gravity calculation
    for (uint i = 0; i < params.bodyCount; i++) {
        if (i == id) continue;
        Body other = inputBodies[i];
        float2 diff = other.position - self.position;
        float distSq = dot(diff, diff) + params.softening * params.softening;
        float invDist = rsqrt(distSq);
        float forceMag = params.G * self.mass * other.mass * invDist * invDist;
        force += forceMag * diff * invDist; // normalize diff inline
    }

    // Semi-implicit Euler
    float2 accel = force / self.mass;
    Body out = self;
    out.velocity += accel * params.dt;
    out.position += out.velocity * params.dt;
    out.angle    += out.angularVel * params.dt;

    // Collision detection and response
    for (uint i = 0; i < params.bodyCount; i++) {
        if (i == id) continue;
        Body other = inputBodies[i];
        float otherRadius = computeBoundingRadius(vertices, other.vertexOffset, other.vertexCount);
        resolveCircleCollision(out, other, selfRadius, otherRadius);
    }

    outputBodies[id] = out;
}

// ─────────────────────────────────────────────────────────
// Vertex / fragment: filled polygon bodies
// ─────────────────────────────────────────────────────────

struct BodyVertOut {
    float4 position [[ position ]];
    float4 color;
    float  selected; // 0 or 1
};

vertex BodyVertOut bodyVert(
    uint                    vid      [[ vertex_id ]],
    constant float2*        verts    [[ buffer(0) ]],
    constant Body*          bodies   [[ buffer(1) ]],
    constant RenderUniforms& uniforms[[ buffer(2) ]],
    constant int&           bodyIdx  [[ buffer(3) ]])
{
    Body b = bodies[bodyIdx];
    float2 local = verts[b.vertexOffset + vid];

    // Rotate
    float c = cos(b.angle), s = sin(b.angle);
    float2 world = b.position + float2(local.x * c - local.y * s,
                                       local.x * s + local.y * c);

    // World → NDC  (camera is center-based)
    float2 offset = (world - uniforms.cameraCenter) / uniforms.cameraScale;
    float ndcX = offset.x;
    float ndcY = offset.y * uniforms.aspectRatio; // correct for non-square viewport

    BodyVertOut out;
    out.position = float4(ndcX, ndcY, 0.5f, 1.0f);
    out.color    = b.color;
    out.selected = float(b.isSelected);
    return out;
}

fragment float4 bodyFrag(BodyVertOut in [[ stage_in ]]) {
    // Brighten selected bodies slightly
    float3 c = in.color.rgb + in.selected * 0.25f;
    return float4(c, in.color.a);
}

// ─────────────────────────────────────────────────────────
// Vertex / fragment: selection outline (line strip per body)
// ─────────────────────────────────────────────────────────

struct OutlineVertOut {
    float4 position [[ position ]];
    float4 color;
};

vertex OutlineVertOut outlineVert(
    uint                    vid      [[ vertex_id ]],
    constant float2*        verts    [[ buffer(0) ]],
    constant Body*          bodies   [[ buffer(1) ]],
    constant RenderUniforms& uniforms[[ buffer(2) ]],
    constant int&           bodyIdx  [[ buffer(3) ]])
{
    Body b = bodies[bodyIdx];
    // Repeat first vertex at end to close the loop
    int count = b.vertexCount;
    int idx   = vid % count;
    float2 local = verts[b.vertexOffset + idx];

    float c = cos(b.angle), s = sin(b.angle);
    float2 world = b.position + float2(local.x * c - local.y * s,
                                       local.x * s + local.y * c);

    float2 offset = (world - uniforms.cameraCenter) / uniforms.cameraScale;
    OutlineVertOut out;
    out.position = float4(offset.x, offset.y * uniforms.aspectRatio, 0.5f, 1.0f);
    out.color    = float4(1.0f, 0.85f, 0.2f, 1.0f); // yellow selection
    return out;
}

fragment float4 outlineFrag(OutlineVertOut in [[ stage_in ]]) {
    return in.color;
}

// ─────────────────────────────────────────────────────────
// Vertex / fragment: 2-D UI overlay (selection rect / lasso)
// Vertices are passed as NDC directly.
// ─────────────────────────────────────────────────────────

struct UIVertOut {
    float4 position [[ position ]];
    float4 color;
};

vertex UIVertOut uiVert(
    uint            vid   [[ vertex_id ]],
    constant float2* verts[[ buffer(0) ]],
    constant float4& color[[ buffer(1) ]])
{
    UIVertOut out;
    out.position = float4(verts[vid], 0.5f, 1.0f);
    out.color    = color;
    return out;
}

fragment float4 uiFrag(UIVertOut in [[ stage_in ]]) {
    return in.color;
}
