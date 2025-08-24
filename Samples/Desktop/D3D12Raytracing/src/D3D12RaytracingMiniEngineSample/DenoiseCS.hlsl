#define HLSL
#define KERNEL_RADIUS 5

cbuffer Constants : register(b0)
{
    float g_DepthWeight;
    float g_NormalWeight;
    float g_ColorWeight;
};

Texture2D<float4>   g_Input                 : register(t0);
Texture2D<float>    g_Depth                 : register(t1);
Texture2D<float4>   g_Normal                : register(t2);
RWTexture2D<float4> g_Output                : register(u0);
SamplerState        g_LinearClampSampler    : register(s0);

[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
    float3 colorSum = float3(0, 0, 0);

    // Simple 3x3 box filter
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            // Sum the colors of the neighboring pixels
            colorSum += g_Input.Load(int3(DTid.xy + int2(x, y), 0)).rgb;
        }
    }
    
    // Average the colors and write to output
    g_Output[DTid.xy] = float4(colorSum / 9.0f, 1.0f);
}
