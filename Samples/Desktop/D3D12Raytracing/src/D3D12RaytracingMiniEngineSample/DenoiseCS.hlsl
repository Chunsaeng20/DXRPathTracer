#define HLSL

Texture2D<float4> InputTexture  : register(t0);
RWTexture2D<float4> OutputTexture : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
	// Simple 3x3 box blur denoising
    float4 sum = 0;
    for (int y = -1; y <= 1; ++y)
    {
        for (int x = -1; x <= 1; ++x)
        {
            sum += InputTexture.Load(int3(DTid.xy + int2(x, y), 0));
        }
    }

    OutputTexture[DTid.xy] = sum / 9.0;
}
