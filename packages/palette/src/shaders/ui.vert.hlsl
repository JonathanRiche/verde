struct VSInput
{
    float2 position : TEXCOORD0;
    float2 uv : TEXCOORD1;
    float4 color : TEXCOORD2;
};

struct VSOutput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : TEXCOORD1;
};

cbuffer PaletteUniforms : register(b0, space1)
{
    float2 viewport_size;
    float2 _padding;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float2 ndc = (input.position / viewport_size) * float2(2.0, -2.0) + float2(-1.0, 1.0);
    output.position = float4(ndc, 0.0, 1.0);
    output.uv = input.uv;
    output.color = input.color;
    return output;
}
