#define HLSL
#include "ModelViewerRaytracing.h"
#include "RayTracingHlslCompat.h"

cbuffer Material : register(b3)
{
    uint MaterialID;
}

StructuredBuffer<RayTraceMeshInfo> g_meshInfo : register(t1);
ByteAddressBuffer g_indices : register(t2);
ByteAddressBuffer g_attributes : register(t3);
Texture2D<float4> g_localTexture : register(t6);

SamplerState defaultSampler : register(s0);

uint3 Load3x16BitIndices(uint offsetBytes)
{
    const uint dwordAlignedOffset = offsetBytes & ~3;
    const uint2 four16BitIndices = g_indices.Load2(dwordAlignedOffset);
    uint3 indices;
    if (dwordAlignedOffset == offsetBytes)
    {
        indices.x = four16BitIndices.x & 0xffff;
        indices.y = (four16BitIndices.x >> 16) & 0xffff;
        indices.z = four16BitIndices.y & 0xffff;
    }
    else
    {
        indices.x = (four16BitIndices.x >> 16) & 0xffff;
        indices.y = four16BitIndices.y & 0xffff;
        indices.z = (four16BitIndices.y >> 16) & 0xffff;
    }
    return indices;
}

float2 GetUVAttribute(uint byteOffset)
{
    uint data = g_attributes.Load(byteOffset);
    return f16tof32(uint2(data & 0xFFFF, data >> 16));
}

// --- Helper functions end here ---

[shader("closesthit")]
void PathTraceHit(inout PathTraceRayPayload payload, in BuiltInTriangleIntersectionAttributes attr)
{
    // Get the material and mesh information of the hit triangle
	uint materialID = MaterialID;
    RayTraceMeshInfo info = g_meshInfo[materialID];
    const uint3 indices = Load3x16BitIndices(info.m_indexOffsetBytes + PrimitiveIndex() * 6);

    // Interpolate the vertex attributes using barycentric coordinates
    const float2 uv0 = GetUVAttribute(info.m_uvAttributeOffsetBytes + indices.x * info.m_attributeStrideBytes);
    const float2 uv1 = GetUVAttribute(info.m_uvAttributeOffsetBytes + indices.y * info.m_attributeStrideBytes);
    const float2 uv2 = GetUVAttribute(info.m_uvAttributeOffsetBytes + indices.z * info.m_attributeStrideBytes);
    float3 bary = float3(1.0 - attr.barycentrics.x - attr.barycentrics.y, attr.barycentrics.x, attr.barycentrics.y);
    float2 uv = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
    
    // Interpolate the normals and transform to world space
    const float3 normal0 = asfloat(g_attributes.Load3(info.m_normalAttributeOffsetBytes + indices.x * info.m_attributeStrideBytes));
    const float3 normal1 = asfloat(g_attributes.Load3(info.m_normalAttributeOffsetBytes + indices.y * info.m_attributeStrideBytes));
    const float3 normal2 = asfloat(g_attributes.Load3(info.m_normalAttributeOffsetBytes + indices.z * info.m_attributeStrideBytes));
    float3 worldNormal = normalize(normal0 * bary.x + normal1 * bary.y + normal2 * bary.z);

    // Write information into the payload
    payload.isHit = 1;
    payload.albedo = g_localTexture.SampleLevel(defaultSampler, uv, 0).rgb;
    payload.worldPos = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    payload.normal = worldNormal;
}

[shader("anyhit")]
void ShadowAnyHit(inout PathTraceRayPayload payload, in BuiltInTriangleIntersectionAttributes attr)
{
    payload.isHit = 1;
}
