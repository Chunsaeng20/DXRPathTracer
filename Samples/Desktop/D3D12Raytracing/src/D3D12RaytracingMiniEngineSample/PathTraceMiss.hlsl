#define HLSL
#include "ModelViewerRaytracing.h"

[shader("miss")]
void PathTraceMiss(inout PathTraceRayPayload payload)
{
	// Indicate that the ray did not hit anything
    payload.isHit = 0;

	// Simple sky gradient
	float t = saturate(WorldRayDirection().y * 0.5 + 0.5);
    payload.color = float4(lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.7, 1.0), t), 1.0);
}

[shader("miss")]
void ShadowMiss(inout PathTraceRayPayload payload)
{
	// No need to do anything, the default value of isHit is 0 (not in shadow)
}
