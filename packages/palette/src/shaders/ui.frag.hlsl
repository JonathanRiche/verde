Texture2D<float4> font_atlas : register(t0, space2);
SamplerState font_sampler : register(s0, space2);

struct PSInput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    float alpha = font_atlas.Sample(font_sampler, input.uv).a;
    return float4(input.color.rgb, input.color.a * alpha);
}
