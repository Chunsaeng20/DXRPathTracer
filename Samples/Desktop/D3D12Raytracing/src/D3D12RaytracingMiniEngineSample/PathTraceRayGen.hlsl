#define HLSL
#include "ModelViewerRaytracing.h"
#include "RandomNumberGenerator.hlsli"

// Cosine weighted hemisphere sampling
float3 SampleHemisphere(float3 normal, uint RNGState)
{
    float r1 = RNG::Random01(RNGState);
    float r2 = RNG::Random01(RNGState);

    float sin_theta = sqrt(r1);
    float cos_theta = sqrt(1.0 - r1);
    float phi = 2.0 * 3.14159265 * r2;

    float x = sin_theta * cos(phi);
    float z = sin_theta * sin(phi);

    float3 tangent = abs(normal.y) > 0.999 ? float3(1, 0, 0) : normalize(cross(normal, float3(0, 1, 0)));
    float3 bitangent = cross(normal, tangent);

    return x * tangent + cos_theta * normal + z * bitangent;
}

// Schlick's approximation for Fresnel factor
float schlick(float cosine, float ref_idx)
{
    float r0 = (1.0 - ref_idx) / (1.0 + ref_idx);
    r0 = r0 * r0;
    return r0 + (1.0 - r0) * pow((1.0 - cosine), 5.0);
}

// Sample a point on a disk representing the directional light source
float3 SampleDirectionalLight(float3 centerDirection, float lightRadius, uint RNGState)
{
    float3 u = abs(centerDirection.y) > 0.999 ? float3(1, 0, 0) : normalize(cross(centerDirection, float3(0, 1, 0)));
    float3 v = cross(centerDirection, u);
    
    float r1 = RNG::Random01(RNGState);
    float r2 = RNG::Random01(RNGState);
    
    float radius = sqrt(r1);
    float theta = 2.0 * 3.14159265 * r2;
    float2 pointOnLightDisk = float2(radius * cos(theta), radius * sin(theta));
    
    return normalize(centerDirection + (pointOnLightDisk.x * u + pointOnLightDisk.y * v) * lightRadius);
}

// --- Helper functions end here ---

RWTexture2D<float4> g_Output : register(u2);

[shader("raygeneration")]
void PathTraceRayGen()
{
	uint2 dispatchIdx = DispatchRaysIndex().xy;
    
    // Create a random seed
    uint pixel_seed = dispatchIdx.x + dispatchIdx.y * g_dynamic.resolution.x;
    uint pixel_hash = RNG::SeedThread(pixel_seed);
    uint final_seed = pixel_hash ^ RNG::SeedThread(g_dynamic.FrameIndex);
    uint RNGState = RNG::SeedThread(final_seed);
    
	// Initialize variables
    float3 finalColor = float3(0, 0, 0);
    float3 throughput = float3(1, 1, 1);

	// Generate initial camera ray
    float3 rayOrigin, rayDirection;
    GenerateCameraRay(dispatchIdx, rayOrigin, rayDirection);
    RayDesc rayDesc = { rayOrigin, 0.01f, rayDirection, 1.0e9f };
    
    // Trace the ray
    for (int i = 0; i < 8; ++i)
    {
        // --- Primary ray ---
        PathTraceRayPayload payload;
        payload.recursionDepth = i;
        payload.isShadowRay = 0;

        TraceRay(g_accel, RAY_FLAG_NONE, 0xFF, 0, 1, 0, rayDesc, payload);
        
        // Miss - add sky color, then terminate
        if (!payload.isHit)
        {			
            finalColor += throughput * payload.color.xyz;
            break;
        }
        
        // Add ambient light only on the first hit
        // Physically not accurate, but more bright
        if (i == 0)
        {
            finalColor += payload.albedo * AmbientColor * 0.2f;
        }

		// --- Next Event Estimation: Direct Light Sampling ---
        float3 lightDir = SampleDirectionalLight(normalize(SunDirection), SunRadius, RNGState);
		float3 shadowRayOrigin = payload.worldPos + payload.normal * 0.001f;
		RayDesc shadowRayDesc = { shadowRayOrigin, 0.001f, lightDir, 1.0e9f };
        
        PathTraceRayPayload shadowPayload;
		shadowPayload.isHit = 0;
        shadowPayload.isShadowRay = 1;
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
            
            // Prevent division by 0
            if (p < 0.0001f)
                break;
            
            // Early termination
            if (RNG::Random01(RNGState) > p)
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
            
            float r1 = RNG::Random01(RNGState);
            float r2 = RNG::Random01(RNGState);
            float r3 = RNG::Random01(RNGState);
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
            if (RNG::Random01(RNGState) < fresnel * 4)
            {
                // --- Specular Reflection ---
                float3 reflectionDir = reflect(incomingDir, payload.normal);
                
                float r1 = RNG::Random01(RNGState);
                float r2 = RNG::Random01(RNGState);
                float r3 = RNG::Random01(RNGState);
                float3 randomVec = normalize(float3(r1, r2, r3) * 2.0 - 1.0);

                float roughnessFactor = payload.roughness * payload.roughness;
                rayDesc.Direction = normalize(lerp(reflectionDir, randomVec, roughnessFactor));
            }
            else
            {
                // --- Diffuse Reflection ---
                rayDesc.Direction = normalize(SampleHemisphere(payload.normal, RNGState));
            }
        }
        // Ensure the new direction is in the same hemisphere as the normal
        if(dot(rayDesc.Direction, payload.normal) < 0.0f)
        {
            rayDesc.Direction = normalize(SampleHemisphere(payload.normal, RNGState));
        }
    }

    g_Output[dispatchIdx] = float4(finalColor, 1.0);
}
