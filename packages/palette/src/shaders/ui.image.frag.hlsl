Texture2D<float4> image_texture : register(t0, space2);
SamplerState image_sampler : register(s0, space2);

struct PSInput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    return image_texture.Sample(image_sampler, input.uv) * input.color;
}
