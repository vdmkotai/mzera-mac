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
fragment float4 yuv(O in [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]], constant float4 &flags [[buffer(0)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float l=y.sample(s,in.uv).r;float2 c=uv.sample(s,in.uv).rg;
    if(flags.z>0.5) {
        // P010 stores 10-bit codes in the high bits of each normalized UInt16.
        l*=65535.0/64.0;c=c*(65535.0/64.0)-512.0;
        if(flags.x<0.5) { l=(l-64.0)/876.0;c/=896.0; }
        else { l/=1023.0;c/=1023.0; }
    } else {
        c-=128.0/255.0;
        if(flags.x<0.5) { l=(l-16.0/255.0)*(255.0/219.0);c*=255.0/224.0; }
    }
    float3 rgb=flags.y>1.5 ? float3(l+1.4746*c.y,l-0.164553*c.x-0.571353*c.y,l+1.8814*c.x) : (flags.y>0.5 ? float3(l+1.402*c.y,l-0.344136*c.x-0.714136*c.y,l+1.772*c.x) : float3(l+1.5748*c.y,l-0.187324*c.x-0.468124*c.y,l+1.8556*c.x));
    return float4(clamp(rgb,0.0,1.0),1.0);
}
