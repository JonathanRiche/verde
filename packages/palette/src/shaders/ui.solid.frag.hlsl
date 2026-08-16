struct PSInput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : TEXCOORD1;
    float2 pixel_pos : TEXCOORD2;
    float2 sdf_min : TEXCOORD3;
    float2 sdf_size : TEXCOORD4;
    float2 sdf_radius_border : TEXCOORD5;
    float4 sdf_border : TEXCOORD6;
};

float sdfRoundedRect(float2 p, float2 half_size, float radius)
{
    float2 d = abs(p) - half_size + radius.xx;
    return length(max(d, 0.0.xx)) + min(max(d.x, d.y), 0.0) - radius;
}

float4 main(PSInput input) : SV_Target0
{
    if (input.sdf_size.x <= 0.0 || input.sdf_size.y <= 0.0) {
        return input.color;
    }

    const float2 center = input.sdf_min + input.sdf_size * 0.5;
    const float2 half_size = input.sdf_size * 0.5;
    const float2 p = input.pixel_pos - center;
    const float radius = input.sdf_radius_border.x;
    const float border_width = input.sdf_radius_border.y;
    const float distance = sdfRoundedRect(p, half_size, radius);
    const float aa_radius = 0.75;

    if (border_width > 0.0 && input.sdf_border.a > 0.0) {
        const float outer_alpha = 1.0 - smoothstep(-aa_radius, aa_radius, distance);
        const float inner_alpha = 1.0 - smoothstep(-aa_radius, aa_radius, distance + border_width);
        const float border_alpha = max(outer_alpha - inner_alpha, 0.0);
        const float4 fill = float4(input.color.rgb, input.color.a * inner_alpha);
        const float border_a = input.sdf_border.a * border_alpha;
        const float3 rgb = input.sdf_border.rgb * border_a + fill.rgb * (1.0 - border_a);
        const float alpha = border_a + fill.a * (1.0 - border_a);
        return float4(rgb, alpha);
    }

    const float alpha = 1.0 - smoothstep(-aa_radius, aa_radius, distance);
    return float4(input.color.rgb, input.color.a * alpha);
}
