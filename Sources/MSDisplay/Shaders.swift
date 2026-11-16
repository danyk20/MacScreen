/// Metal Shading Language source, compiled at runtime (no .metal files in the package).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Full-screen triangle from vertex_id; uv (0,0) is the top-left of the image.
    vertex VertexOut ms_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);          // (0,0) (2,0) (0,2)
        VertexOut out;
        out.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
        out.uv = p;
        return out;
    }

    // BT.709 video range Y'CbCr -> gamma-encoded R'G'B' (values written unchanged).
    fragment float4 ms_fragment(VertexOut in [[stage_in]],
                                texture2d<float> lumaTex [[texture(0)]],
                                texture2d<float> chromaTex [[texture(1)]]) {
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float y  = lumaTex.sample(s, in.uv).r;
        float2 c = chromaTex.sample(s, in.uv).rg;
        float Y  = (y - 16.0 / 255.0) * 255.0 / 219.0;
        float Cb = (c.x - 128.0 / 255.0) * 255.0 / 224.0;
        float Cr = (c.y - 128.0 / 255.0) * 255.0 / 224.0;
        float3 rgb = float3(Y + 1.5748 * Cr,
                            Y - 0.1873 * Cb - 0.4681 * Cr,
                            Y + 1.8556 * Cb);
        return float4(saturate(rgb), 1.0);
    }
    """
}
