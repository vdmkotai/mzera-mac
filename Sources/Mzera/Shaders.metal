#include <metal_stdlib>
using namespace metal;
struct V { float2 pos; float2 uv; float4 color; };
struct O { float4 pos [[position]]; float2 uv; float4 color; };
vertex O mz_vertex(uint id [[vertex_id]], const device V *v [[buffer(0)]]) {
    O o; o.pos=float4(v[id].pos,0,1);o.uv=v[id].uv;o.color=v[id].color;return o;
}
fragment float4 rgba(O in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    return t.sample(s,in.uv)*in.color;
}
fragment float4 yuv(O in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]], constant float2 &flags [[buffer(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float l=y.sample(s,in.uv).r;float2 c=uv.sample(s,in.uv).rg-0.5;
    if(flags.x<0.5) { l=(l-16.0/255.0)*(255.0/219.0);c*=255.0/224.0; }
    float3 rgb=flags.y>0.5 ? float3(l+1.402*c.y,l-0.344136*c.x-0.714136*c.y,l+1.772*c.x) : float3(l+1.5748*c.y,l-0.187324*c.x-0.468124*c.y,l+1.8556*c.x);
    return float4(clamp(rgb,0.0,1.0),1.0);
}
