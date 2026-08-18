#include "common.hlsl"

// Mana sight lens, projected as a holographic panel from the condensator hand.
// The panel's four projected screen corners come from Lua; inside that quad
// the scene is regraded as a dark brass etching (near-black umber base, etched
// bright line work on edges, grain, scanlines); outside is untouched.  The
// panel's gold deco edges and labels are drawn over this in Lua.
//
// Constants0: x = time, y = ramp (0-1 materialize), z = aspect (w/h), w unused
// Constants1: xy = corner TL (uv), zw = corner TR (uv)
// Constants2: xy = corner BR (uv), zw = corner BL (uv)
#define TIME   Constants0.x
#define RAMP   Constants0.y
#define ASPECT Constants0.z

// Brass-plate palette: near-black umber paper, the etched line work carries the
// image.  A dark highlight ceiling keeps flat fields (the skybox) dark, which
// doubles as the lens's limited-vision look without touching engine fog.
#define INK       float3(0.030, 0.021, 0.008)
#define HILITE    float3(0.21, 0.16, 0.07)
#define EDGE_COL  float3(1.00, 0.88, 0.52)
#define EDGE_STR  0.85
#define GLOW_COL  float3(0.95, 0.72, 0.28)
#define GRAIN     0.05

struct PS_IN { float2 uv : TEXCOORD0; };

float hash2(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float lum(float3 c)
{
	return dot(c, float3(0.299, 0.587, 0.114));
}

// Signed distance from p to the edge a->b (aspect-corrected units)
float edgeDist(float2 a, float2 b, float2 p)
{
	float2 e = b - a;
	float2 n = normalize(float2(e.y, -e.x));
	return dot(p - a, n);
}

float4 main(PS_IN i) : COLOR
{
	float3 screenCol = tex2D(TexBase, i.uv).rgb;

	if (RAMP <= 0.001)
	{
		return float4(screenCol, 1.0);
	}

	float2 texel = float2(abs(ddx(i.uv.x)), abs(ddy(i.uv.y)));
	float2 asp = float2(ASPECT, 1.0);
	float2 p = i.uv * asp;

	float2 tl = Constants1.xy * asp;
	float2 tr = Constants1.zw * asp;
	float2 br = Constants2.xy * asp;
	float2 bl = Constants2.zw * asp;

	// Inside the convex quad all four signed distances share a sign; taking the
	// worst of both windings makes the test orientation-agnostic
	float d0 = edgeDist(tl, tr, p);
	float d1 = edgeDist(tr, br, p);
	float d2 = edgeDist(br, bl, p);
	float d3 = edgeDist(bl, tl, p);
	float insideA = min(min(d0, d1), min(d2, d3));
	float insideB = min(min(-d0, -d1), min(-d2, -d3));
	float inside = max(insideA, insideB);

	if (inside < -0.002)
	{
		return float4(screenCol, 1.0);
	}

	float window = smoothstep(-0.002, 0.002, inside) * RAMP;

	// Approximate panel-vertical coordinate for the scanlines: distance from
	// the top edge over the total top+bottom distance (perspective-stable)
	float dTop = abs(d0);
	float dBot = abs(d2);
	float v = dTop / max(dTop + dBot, 1e-5);

	// Slight chromatic offset pulling toward the panel center, glass-like
	float2 center = (tl + tr + br + bl) * 0.25;
	float2 radial = normalize(p - center + 1e-4);
	float edgeNear = 1.0 - smoothstep(0.0, 0.06, inside);
	float2 chroma = radial * edgeNear * edgeNear * 0.0018;
	float3 col;
	col.r = tex2D(TexBase, i.uv + chroma).r;
	col.g = screenCol.g;
	col.b = tex2D(TexBase, i.uv - chroma).b;

	// Blueprint duotone: a BANDPASS ramp, not a linear one.  Midtones (world
	// geometry) get the highlight colour; very bright flats (the skybox) fall
	// back to ink so the sky reads as black paper through the lens.
	float l = lum(col);
	float t = smoothstep(0.04, 0.35, l) * (1.0 - smoothstep(0.45, 0.62, l));
	t = t * t * (3.0 - 2.0 * t);
	float3 graded = lerp(INK, HILITE, t);

	// Etched line work from the scene's luminance gradient.  Suppressed when
	// any neighbour is sky-bright, otherwise the sky/world horizon boundary
	// draws itself as a line that has no business existing.
	float lE = lum(tex2D(TexBase, i.uv + float2(texel.x, 0)).rgb);
	float lW = lum(tex2D(TexBase, i.uv - float2(texel.x, 0)).rgb);
	float lS = lum(tex2D(TexBase, i.uv + float2(0, texel.y)).rgb);
	float lN = lum(tex2D(TexBase, i.uv - float2(0, texel.y)).rgb);
	float brightest = max(max(lE, lW), max(max(lS, lN), l));
	float skyMask = 1.0 - smoothstep(0.48, 0.60, brightest);
	float edge = smoothstep(0.06, 0.4, abs(lE - lW) + abs(lS - lN));
	graded = lerp(graded, EDGE_COL, edge * EDGE_STR * skyMask);

	// Holo scanlines drifting down the panel + animated grain in the shadows
	float scan = 0.035 * sin(v * 220.0 - TIME * 2.6);
	graded *= 1.0 + scan;
	float g = hash2(i.uv / max(texel, 1e-6) * 0.5 + frac(TIME * 7.31) * 61.7);
	graded += (g - 0.5) * GRAIN * (1.0 - t * 0.6);

	// Soft gold glow hugging the inside of the panel edge
	float glow = 1.0 - smoothstep(0.0, 0.02, inside);
	graded += GLOW_COL * glow * glow * 0.35;

	return float4(lerp(screenCol, graded, window), 1.0);
}
