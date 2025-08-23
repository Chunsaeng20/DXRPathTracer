#define HLSL
#include "ModelViewerRaytracing.h"

uint pcg_hash_2(uint2 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v = v ^ (v >> 16u);
    v.x += v.y * 1664525u;
    v.y += v.x * 1664525u;
    v = v ^ (v >> 16u);
    return v.x + v.y;
}

float random_float(uint2 pixelCoord, uint frameIndex, uint sampleIndex)
{
    uint seed = pcg_hash_2(pixelCoord + uint2(frameIndex, sampleIndex));
    return float(seed) / float(0xFFFFFFFFu);
}

// Cosine weighted hemisphere sampling
float3 SampleHemisphere(float3 normal, uint2 pixelCoord, uint frameIndex, inout uint sampleIndex)
{
    float r1 = random_float(pixelCoord, frameIndex, sampleIndex++);
    float r2 = random_float(pixelCoord, frameIndex, sampleIndex++);

    float sin_theta = sqrt(r1);
    float cos_theta = sqrt(1.0 - r1);
    float phi = 2.0 * 3.14159265 * r2;

    float x = sin_theta * cos(phi);
    float z = sin_theta * sin(phi);

    float3 tangent = abs(normal.y) > 0.999 ? float3(1, 0, 0) : normalize(cross(normal, float3(0, 1, 0)));
    float3 bitangent = cross(normal, tangent);

    return x * tangent + cos_theta * normal + z * bitangent;
}

float schlick(float cosine, float ref_idx)
{
    float r0 = (1.0 - ref_idx) / (1.0 + ref_idx);
    r0 = r0 * r0;
    return r0 + (1.0 - r0) * pow((1.0 - cosine), 5.0);
}

// --- Helper functions end here ---

RWTexture2D<float4> g_Output : register(u2);

[shader("raygeneration")]
void PathTraceRayGen()
{
	uint2 dispatchIdx = DispatchRaysIndex().xy;
    uint sampleIndex = 0;
    
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
        
        // Add ambient light only on the first hit
        // Physically not accurate, but more bright
        if (i == 0)
        {
            finalColor += payload.albedo * AmbientColor * 0.1f;
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
            if (random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++) > p)
                break;
            throughput /= p;
		}
        
        // Prepare the next ray
        rayDesc.Origin = payload.worldPos + payload.normal * 0.001f;
        
        // Reflect or diffuse based on material
        float3 incomingDir = rayDesc.Direction;
        if(payload.metalic > 0.8f)
        {
            // --- Specular Reflection for metallic surfaces ---
            float3 reflectionDir = reflect(incomingDir, payload.normal);
            
            float r1 = random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++);
            float r2 = random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++);
            float r3 = random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++);
            float3 randomVec = normalize(float3(r1, r2, r3) * 2.0 - 1.0);
            
            float roughnessFactor = payload.roughness * payload.roughness;
            rayDesc.Direction = normalize(lerp(reflectionDir, randomVec, roughnessFactor));
        }
        else
        {
            // --- Reflection for non-metallic surfaces ---
            float cosine = dot(payload.normal, -incomingDir);
            float fresnel = schlick(cosine, 1.5);
            
            // Mix between reflection and diffuse based on Fresnel term
            if (random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++) < fresnel * 4)
            {
                // --- Specular Reflection ---
                float3 reflectionDir = reflect(incomingDir, payload.normal);
                
                float r1 = random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++);
                float r2 = random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++);
                float r3 = random_float(dispatchIdx, g_dynamic.FrameIndex, sampleIndex++);
                float3 randomVec = normalize(float3(r1, r2, r3) * 2.0 - 1.0);

                float roughnessFactor = payload.roughness * payload.roughness;
                rayDesc.Direction = normalize(lerp(reflectionDir, randomVec, roughnessFactor));
            }
            else
            {
                // --- Diffuse Reflection ---
                rayDesc.Direction = normalize(SampleHemisphere(payload.normal, dispatchIdx, g_dynamic.FrameIndex, sampleIndex));
            }
        }
        // Ensure the new direction is in the same hemisphere as the normal
        if(dot(rayDesc.Direction, payload.normal) < 0.0f)
        {
            rayDesc.Direction = normalize(SampleHemisphere(payload.normal, dispatchIdx, g_dynamic.FrameIndex, sampleIndex));
        }
    }

    g_Output[dispatchIdx] = float4(finalColor, 1.0);
}
