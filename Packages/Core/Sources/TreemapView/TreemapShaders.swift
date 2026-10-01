/// Metal source for the treemap, compiled at runtime so the package builds with plain
/// `swift build` (SwiftPM doesn't compile .metal files outside Xcode).
enum TreemapShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float4 rect;   // x, y, width, height in pixels, y down
        float4 shade;  // bx, ax, by, ay: surface slope at u is b + a·u, u relative to rect origin
        float4 color;  // rgb, w = 1 for cushion shading, 0 for a solid fill
    };

    struct Fragment {
        float4 position [[position]];
        float2 local;
        float4 shade [[flat]];
        float4 color [[flat]];
    };

    vertex Fragment treemap_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   const device Instance *instances [[buffer(0)]],
                                   constant float2 &viewport [[buffer(1)]]) {
        Instance item = instances[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 local = corner * item.rect.zw;
        float2 p = item.rect.xy + local;
        Fragment out;
        out.position = float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
        out.local = local;
        out.shade = item.shade;
        out.color = item.color;
        return out;
    }

    fragment float4 treemap_fragment(Fragment in [[stage_in]]) {
        if (in.color.w < 0.5) { return float4(in.color.rgb, 1.0); }
        // Cushion shading: van Wijk & van de Wetering, 1999.
        const float3 light = float3(0.09759, 0.19518, 0.9759);
        const float ambient = 0.2;
        const float diffuse = 0.8;
        float nx = -(in.shade.x + in.shade.y * in.local.x);
        float ny = -(in.shade.z + in.shade.w * in.local.y);
        float cosine = (nx * light.x + ny * light.y + light.z) * rsqrt(nx * nx + ny * ny + 1.0);
        float intensity = ambient + diffuse * max(0.0, cosine);
        return float4(min(in.color.rgb * intensity, 1.0), 1.0);
    }
    """
}
