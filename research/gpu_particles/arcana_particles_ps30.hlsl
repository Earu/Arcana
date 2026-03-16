#include "common.hlsl"

// Constants0: x = time (for animation)
#define TIME Constants0.x

struct PS_IN
{
	float2 uv        : TEXCOORD0; // Standard UV for texture sampling
	float4 color     : TEXCOORD1;
	float2 pos       : VPOS;
};

// Simple noise for particle texture
float hash(float2 p)
{
	return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float noise(float2 p)
{
	float2 i = floor(p);
	float2 f = frac(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + float2(1.0, 0.0));
	float c = hash(i + float2(0.0, 1.0));
	float d = hash(i + float2(1.0, 1.0));

	return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float4 main(PS_IN i) : COLOR
{
	// Sample the texture directly with UVs (standard approach)
	float4 texColor = tex2D(TexBase, i.uv);

	// Apply vertex color
	float4 finalColor = texColor * i.color;

	// Discard fully transparent pixels
	if (finalColor.a < 0.01)
	{
		discard;
	}

	return finalColor;
}
