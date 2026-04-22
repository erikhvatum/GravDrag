#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────
// Shared types (must exactly mirror Swift GPUBody struct)
// ─────────────────────────────────────────────────────────

struct Body {
    float2 position;        // 8
    float2 velocity;        // 8
    float  radius;          // 4
    float  angle;           // 4
    float  angularVel;      // 4
    float  mass;            // 4
    float  momentOfInertia; // 4
    int    vertexOffset;    // 4
    int    vertexCount;     // 4
    float  colorR;          // 4
    float  colorG;          // 4
    float  colorB;          // 4
    float  colorA;          // 4
    int    isStatic;        // 4
    int    isSelected;      // 4
    int    isFocused;       // 4
    int    _padding;        // 4
    float  _padding2;       // 4 (explicit to keep 80-byte stride with 8-byte alignment)
    // 80 bytes total (Metal rounds to 8-byte alignment)
};

struct SimParams {
    uint  bodyCount;
    float dt;
    float G;
    float softening;
};

struct RenderUniforms {
    float2 cameraCenter;
    float  cameraScale;
    float  aspectRatio;
};

// ─────────────────────────────────────────────────────────
// Helper Functions
// ─────────────────────────────────────────────────────────

float computeBoundingRadius(constant float2* vertices, int offset, int count) {
    float maxDist = 0.0f;
    for (int i = 0; i < count; i++) {
        float2 v = vertices[offset + i];
        float dist = length(v);
        maxDist = max(maxDist, dist);
    }
    return maxDist;
}

bool resolveCircleCollision(thread Body& self, Body other, float selfRadius, float otherRadius) {
    float2 diff = other.position - self.position;
    float dist = length(diff);
    float minDist = selfRadius + otherRadius;

    if (dist < minDist && dist > 0.001f) {
        float2 normal = diff / dist;
        float overlap = minDist - dist;
        self.position -= normal * (overlap * 0.5f);

        float2 relVel = self.velocity - other.velocity;
        float velAlongNormal = dot(relVel, normal);

        if (velAlongNormal > 0.0f) return true;

        float impulse = -(2.0f * velAlongNormal) / (1.0f / self.mass + 1.0f / other.mass);
        float2 impulseVec = impulse * normal / self.mass;
        self.velocity += impulseVec;

        return true;
    }
    return false;
}

// ─────────────────────────────────────────────────────────
// Compute: Two-Pass Velocity Verlet Integration
// ─────────────────────────────────────────────────────────

kernel void verletPass1(
    constant Body* inputBodies        [[ buffer(0) ]],
    device   Body* intermediateBodies [[ buffer(1) ]],
    constant SimParams& params        [[ buffer(2) ]],
    uint id [[ thread_position_in_grid ]])
{
    if (id >= params.bodyCount) return;
    
    Body self = inputBodies[id];
    if (self.isStatic) {
        intermediateBodies[id] = self;
        return;
    }

    // 1. Calculate initial acceleration a(t)
    float2 force = float2(0.0f, 0.0f);
    for (uint i = 0; i < params.bodyCount; i++) {
        if (i == id) continue;
        Body other = inputBodies[i];
        float2 diff = other.position - self.position;
        float distSq = dot(diff, diff);
        if (distSq < 1e-12f) continue; // overlapping centers; skip to avoid NaNs
        float minDist = self.radius + other.radius;
        float clampedDistSq = max(distSq, minDist * minDist + params.softening * params.softening);
        float invDist = rsqrt(clampedDistSq);
        float forceMag = params.G * self.mass * other.mass * invDist * invDist;
        force += forceMag * (diff * invDist);
    }
    float2 accel = force / self.mass;

    // 2. Velocity half-kick: v(t + dt/2) = v(t) + a(t) * dt/2
    self.velocity += accel * (0.5f * params.dt);

    // 3. Full position step: p(t + dt) = p(t) + v(t + dt/2) * dt
    self.position += self.velocity * params.dt;
    self.angle    += self.angularVel * params.dt;

    intermediateBodies[id] = self;
}

kernel void verletPass2(
    constant Body* intermediateBodies [[ buffer(0) ]],
    device   Body* outputBodies       [[ buffer(1) ]],
    constant SimParams& params        [[ buffer(2) ]],
    constant float2* vertices         [[ buffer(3) ]],
    uint id [[ thread_position_in_grid ]])
{
    if (id >= params.bodyCount) return;
    
    Body self = intermediateBodies[id];
    if (self.isStatic) {
        outputBodies[id] = self;
        return;
    }

    // 1. Calculate new acceleration a(t + dt) using EVERYONE'S new position
    float2 force = float2(0.0f, 0.0f);
    for (uint i = 0; i < params.bodyCount; i++) {
        if (i == id) continue;
        Body other = intermediateBodies[i]; // Reading updated positions
        float2 diff = other.position - self.position;
        float distSq = dot(diff, diff);
        if (distSq < 1e-12f) continue;
        float minDist = self.radius + other.radius;
        float clampedDistSq = max(distSq, minDist * minDist + params.softening * params.softening);
        float invDist = rsqrt(clampedDistSq);
        float forceMag = params.G * self.mass * other.mass * invDist * invDist;
        force += forceMag * (diff * invDist);
    }
    float2 accel = force / self.mass;

    // 2. Second half-kick: v(t + dt) = v(t + dt/2) + a(t + dt) * dt/2
    self.velocity += accel * (0.5f * params.dt);

    outputBodies[id] = self;
}

// ─────────────────────────────────────────────────────────
// Vertex / fragment: filled polygon bodies
// ─────────────────────────────────────────────────────────

struct BodyVertOut {
    float4 position [[ position ]];
    float4 color;
    float  selected;
};

vertex BodyVertOut bodyVert(
    uint                    vid      [[ vertex_id ]],
    constant float2* verts    [[ buffer(0) ]],
    constant Body* bodies   [[ buffer(1) ]],
    constant RenderUniforms& uniforms[[ buffer(2) ]],
    constant int&           bodyIdx  [[ buffer(3) ]])
{
    Body b = bodies[bodyIdx];
    float2 local = verts[b.vertexOffset + vid];

    float c = cos(b.angle), s = sin(b.angle);
    float2 world = b.position + float2(local.x * c - local.y * s,
                                       local.x * s + local.y * c);

    float2 offset = (world - uniforms.cameraCenter) / uniforms.cameraScale;
    
    BodyVertOut out;
    out.position = float4(offset.x, offset.y * uniforms.aspectRatio, 0.5f, 1.0f);
    out.color    = float4(b.colorR, b.colorG, b.colorB, b.colorA);
    out.selected = float(b.isSelected);
    return out;
}

fragment float4 bodyFrag(BodyVertOut in [[ stage_in ]]) {
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
    constant float2* verts    [[ buffer(0) ]],
    constant Body* bodies   [[ buffer(1) ]],
    constant RenderUniforms& uniforms[[ buffer(2) ]],
    constant int&           bodyIdx  [[ buffer(3) ]])
{
    Body b = bodies[bodyIdx];
    int count = b.vertexCount;
    int idx   = vid % count;
    float2 local = verts[b.vertexOffset + idx];

    float c = cos(b.angle), s = sin(b.angle);
    float2 world = b.position + float2(local.x * c - local.y * s,
                                       local.x * s + local.y * c);

    float2 offset = (world - uniforms.cameraCenter) / uniforms.cameraScale;
    OutlineVertOut out;
    out.position = float4(offset.x, offset.y * uniforms.aspectRatio, 0.5f, 1.0f);
    out.color    = float4(1.0f, 0.85f, 0.2f, 1.0f);
    return out;
}

fragment float4 outlineFrag(OutlineVertOut in [[ stage_in ]]) {
    return in.color;
}

// ─────────────────────────────────────────────────────────
// Vertex / fragment: 2-D UI overlay (selection rect / lasso)
// ─────────────────────────────────────────────────────────

struct UIVertOut {
    float4 position [[ position ]];
    float4 color;
};

vertex UIVertOut uiVert(
    uint            vid  [[ vertex_id ]],
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
