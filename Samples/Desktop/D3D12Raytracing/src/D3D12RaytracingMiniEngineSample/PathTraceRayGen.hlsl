#define HLSL
#include "ModelViewerRaytracing.h"

// Hash Function for GPU Rendering
// https://www.jcgt.org/published/0009/03/02/
uint pcg_hash(uint input)
{
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float random_float(inout uint seed)
{
    seed = pcg_hash(seed);
    return float(seed) / float(0xFFFFFFFFu);
}

// Cosine weighted hemisphere sampling
float3 SampleHemisphere(float3 normal, inout uint seed)
{
    float r1 = random_float(seed);
    float r2 = random_float(seed);

    float sin_theta = sqrt(r1);
    float cos_theta = sqrt(1.0 - r1);
    float phi = 2.0 * 3.14159265 * r2;

    float x = sin_theta * cos(phi);
    float z = sin_theta * sin(phi);

    float3 tangent = abs(normal.y) > 0.999 ? float3(1, 0, 0) : normalize(cross(normal, float3(0, 1, 0)));
    float3 bitangent = cross(normal, tangent);

    return x * tangent + cos_theta * normal + z * bitangent;
}

// --- Helper functions end here ---

RWTexture2D<float4> g_Output : register(u2);

[shader("raygeneration")]
void PathTraceRayGen()
{
	uint2 dispatchIdx = DispatchRaysIndex().xy;
    uint seed = dispatchIdx.x + dispatchIdx.y * g_dynamic.resolution.x + g_dynamic.FrameIndex * 123456;
    
	// Initialize variables
    float3 finalColor = float3(0, 0, 0);
    float3 throughput = float3(1, 1, 1);

	// Generate initial camera ray
    float3 rayOrigin, rayDirection;
    GenerateCameraRay(dispatchIdx, rayOrigin, rayDirection);
    RayDesc rayDesc = { rayOrigin, 0.01f, rayDirection, 1.0e9f };
    
    for (int i = 0; i < 8; ++i)
    {
        PathTraceRayPayload payload;
        payload.recursionDepth = i;

        TraceRay(g_accel, RAY_FLAG_NONE, 0xFF, 0, 1, 0, rayDesc, payload);

        if (!payload.isHit)
        {
			// Miss - add sky color, then terminate
            finalColor += throughput * payload.color.xyz;
            break;
        }

		// --- Next Event Estimation: Direct Light Sampling ---
        float3 lightDir = SunDirection;
		float3 shadowRayOrigin = payload.worldPos + payload.normal * 0.001f;
		RayDesc shadowRayDesc = { shadowRayOrigin, 0.001f, lightDir, 1.0e9f };
        
        PathTraceRayPayload shadowPayload;
		shadowPayload.isHit = 0;
        TraceRay(g_accel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xFF, 0, 1, 0, shadowRayDesc, shadowPayload);

        if (!shadowPayload.isHit)
        {
            float NdotL = saturate(dot(payload.normal, lightDir));
            finalColor += throughput * payload.albedo * SunColor * NdotL;
        }

        // --- Decrement throughput ---
		throughput *= payload.albedo;

		// --- Russian Roulette Termination ---
        if (i >= 2)
        {
            float p = max(throughput.x, max(throughput.y, throughput.z));
            if (random_float(seed) > p)
                break;
            throughput /= p;
		}
        
        // Prepare the next ray
        rayDesc.Origin = payload.worldPos + payload.normal * 0.001f;
        rayDesc.Direction = normalize(SampleHemisphere(payload.normal, seed));
    }

    g_Output[dispatchIdx] = float4(finalColor, 1.0);
}
