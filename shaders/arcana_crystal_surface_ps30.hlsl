#include "common.hlsl"

#define DISPERSION_STRENGTH Constants0.x
#define FRESNEL_POWER       Constants0.y
#define TINT_R              Constants0.z
#define TINT_G              Constants0.w
#define TINT_B              Constants1.x
#define OPACITY             Constants1.y

// Extra controls
#define NOISE_TIME          Constants2.x
#define NOISE_SCALE         Constants2.y
#define GRAIN_STRENGTH      Constants2.z
#define SPARKLE_STRENGTH    Constants2.w

// Multi-bounce + facetization controls
#define THICKNESS_SCALE     Constants3.x   // screen-space step per bounce
#define FACET_QUANT         Constants3.y   // e.g. 6..24, snaps normals
#define BOUNCE_FADE         Constants3.z   // 0..1 weight decay
#define BOUNCE_STEPS        Constants3.w   // 1..4 effective steps

struct PS_IN
{
	float2 uv        : TEXCOORD0;
	float4 color     : TEXCOORD1;
	float2 pos       : VPOS;
	// from vs: pack normal in TEXCOORD2 (xyz). alpha unused
	float3 normal    : TEXCOORD2;
};

// Cheap value noise
float hash21(float2 p)
{
	p = frac(p * float2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return frac(p.x * p.y);
}

float noise2(float2 p)
{
	float2 i = floor(p);
	float2 f = frac(p);
	float a = hash21(i);
	float b = hash21(i + float2(1, 0));
	float c = hash21(i + float2(0, 1));
	float d = hash21(i + float2(1, 1));
	float2 u = f * f * (3.0 - 2.0 * f);
	return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float3 sampleScene(float2 uv)
{
	float3 col = tex2D(TexBase, uv).rgb;
	return col;
}

float fresnelTerm(float3 n, float3 v, float p)
{
	float f = 1.0 - saturate(dot(n, -v));
	return pow(f, p);
}

float3 facetizeNormal(float3 n)
{
	float q = max(FACET_QUANT, 1.0);
	return normalize(round(n * q) / q);
}

float4 main(PS_IN i) : COLOR
{
	// Approximate view dir from screen center; screenspace_general lacks world pos here
	float2 screen = (i.pos.xy * TexBaseSize.xy);
	float2 centered = (screen * 2.0 - 1.0);
	float3 viewDir = normalize(float3(centered, 1.0));
	float3 n = normalize(i.normal);

	float f = fresnelTerm(n, viewDir, max(FRESNEL_POWER, 0.5));

	// Grain (animated)
	float g = noise2(screen * max(NOISE_SCALE, 0.1) + NOISE_TIME * 0.5);
	float grain = lerp(1.0 - GRAIN_STRENGTH, 1.0 + GRAIN_STRENGTH, g);

	// Multi-bounce refractive walk in screen space with facetized normals
	float2 baseUV = saturate(screen);
	float3 view = normalize(float3(centered, 1.0));
	float3 nFacet = facetizeNormal(n);

	float etaBase = 1.0 / 1.2;             // glass-ish
	float dIor    = DISPERSION_STRENGTH * 0.05;
	float etaR = etaBase - dIor;
	float etaG = etaBase;
	float etaB = etaBase + dIor;

	float2 uvR = baseUV, uvG = baseUV, uvB = baseUV;
	float3 rdR = view,   rdG = view,   rdB = view;
	int stepsCount = (int)clamp(BOUNCE_STEPS, 1.0, 4.0);
	float fade = saturate(BOUNCE_FADE);
	float3 accum = 0.0;
	float weightSum = 0.0;

	[unroll]
	for (int k = 0; k < 4; ++k)
	{
		if (k >= stepsCount) break;

		float3 rr = refract(rdR, nFacet, etaR); if (all(rr == 0)) rr = reflect(rdR, nFacet);
		float3 rg = refract(rdG, nFacet, etaG); if (all(rg == 0)) rg = reflect(rdG, nFacet);
		float3 rb = refract(rdB, nFacet, etaB); if (all(rb == 0)) rb = reflect(rdB, nFacet);

		float2 dR = rr.xy / max(abs(rr.z), 1e-3) * THICKNESS_SCALE * grain;
		float2 dG = rg.xy / max(abs(rg.z), 1e-3) * THICKNESS_SCALE * grain;
		float2 dB = rb.xy / max(abs(rb.z), 1e-3) * THICKNESS_SCALE * grain;

		uvR += dR; uvG += dG; uvB += dB;

		float3 sR = sampleScene(uvR);
		float3 sG = sampleScene(uvG);
		float3 sB = sampleScene(uvB);

		float3 dispRGB = float3(sR.r, sG.g, sB.b);
		float w = pow(fade, k);
		accum += dispRGB * w;
		weightSum += w;

		rdR = rr; rdG = rg; rdB = rb;
		nFacet = facetizeNormal(normalize(nFacet + float3(0.11, -0.07, 0.05)));
	}

	float3 dispersed = accum / max(weightSum, 1e-3);

	float3 tint = float3(TINT_R, TINT_G, TINT_B);
	float3 finalCol = lerp(dispersed, dispersed * tint, 0.5);
	finalCol *= (0.2 + 0.8 * f);

	// Sparkles: rarity driven by noise threshold and view alignment
	float sparkleMask = step(0.85, noise2(screen * (NOISE_SCALE * 0.5) + NOISE_TIME * 0.8));
	float sparkleFacing = pow(saturate(1.0 - abs(dot(n, viewDir))), 8.0);
	finalCol += sparkleMask * sparkleFacing * SPARKLE_STRENGTH;

	float alpha = saturate(OPACITY) * (0.2 + 0.8 * f) * i.color.a;
	return float4(finalCol, alpha);
}