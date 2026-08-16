#include "common.hlsl"

// Crystal ghost fill for the mana sight panel.  Drawn as a screen quad
// stencil-masked to the crystal's silhouette (which itself ripples: the
// marking pass rasterizes the model with animated render-origin jitters).
// The frame beneath is sampled with a layered sine wobble and per-channel
// offsets (chromatic fringing), its luminance becomes facet structure, and
// energy veins are evaluated as 3D noise at a RECONSTRUCTED WORLD POSITION:
// the pixel's view ray projected to the anchor crystal's depth.  That keeps
// the veins pinned to the crystal under camera rotation AND movement.
//
// Constants0: x = time, y = pulse, z = anchor radius, w = halfH (ray scale)
// Constants1: xyz = eye position,        w = anchor centre X
// Constants2: xyz = camera right * halfW, w = anchor centre Y
// Constants3: xyz = camera forward,       w = anchor centre Z
#define TIME    Constants0.x
#define PULSE   Constants0.y
#define RADIUS  Constants0.z
#define HALF_H  Constants0.w
#define EYE     Constants1.xyz
#define RIGHT_S Constants2.xyz
#define FWD     Constants3.xyz

#define GHOST float3(0.88, 0.76, 1.00)

struct PS_IN { float2 uv : TEXCOORD0; };

float hash3(float3 p)
{
	return frac(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float noise3(float3 p)
{
	float3 ip = floor(p);
	float3 f = frac(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash3(ip);
	float n100 = hash3(ip + float3(1, 0, 0));
	float n010 = hash3(ip + float3(0, 1, 0));
	float n110 = hash3(ip + float3(1, 1, 0));
	float n001 = hash3(ip + float3(0, 0, 1));
	float n101 = hash3(ip + float3(1, 0, 1));
	float n011 = hash3(ip + float3(0, 1, 1));
	float n111 = hash3(ip + float3(1, 1, 1));

	float nx00 = lerp(n000, n100, f.x);
	float nx10 = lerp(n010, n110, f.x);
	float nx01 = lerp(n001, n101, f.x);
	float nx11 = lerp(n011, n111, f.x);

	return lerp(lerp(nx00, nx10, f.y), lerp(nx01, nx11, f.y), f.z);
}

float4 main(PS_IN i) : COLOR
{
	// Layered sine wobble: organic, non-repeating-looking warp
	float2 sp = float2(i.uv.x * 1.78, i.uv.y);
	float2 off;
	off.x = sin(sp.y * 46.0 + TIME * 2.6) + 0.6 * sin(sp.y * 91.0 - TIME * 4.1) + 0.4 * sin(sp.x * 57.0 + TIME * 1.7);
	off.y = sin(sp.x * 41.0 - TIME * 2.2) + 0.6 * sin(sp.x * 83.0 + TIME * 3.6) + 0.4 * sin(sp.y * 63.0 - TIME * 1.3);
	off *= 0.0035;

	// Chromatic split: each channel refracts by a different amount
	float3 col;
	col.r = tex2D(TexBase, i.uv + off * 1.5).r;
	col.g = tex2D(TexBase, i.uv + off).g;
	col.b = tex2D(TexBase, i.uv + off * 0.5).b;
	float l = dot(col, float3(0.299, 0.587, 0.114));

	// World-position proxy: this pixel's ray, walked out to the anchor
	// crystal's depth.  For pixels on the crystal it approximates the actual
	// surface position, so noise there holds still as the camera moves.
	float3 center = float3(Constants1.w, Constants2.w, Constants3.w);
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 vup = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + vup * ndc.y);
	float tProj = max(dot(center - EYE, dir), 0.0);
	float3 wp = (EYE + dir * tProj - center) / max(RADIUS, 1.0);

	// Rising energy veins, world-anchored.  A single coarse octave whose
	// features are large enough to resolve at ANY distance: no LOD, no
	// transitions, the crystal looks the same at every range.
	float3 drift = float3(0.0, 0.0, -TIME * 0.35);
	float n1 = noise3(wp * 1.4 + drift);
	float veins = pow(saturate(1.0 - abs(n1 * 2.0 - 1.0) * 1.4), 3.0);

	float3 outCol = GHOST * (0.42 + 0.36 * l) * PULSE;
	outCol += float3(1.00, 0.92, 1.00) * veins * 1.15;

	return float4(outCol, 1.0);
}
