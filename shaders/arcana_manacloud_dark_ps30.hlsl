#include "common.hlsl"

// DARK variant: immature mana concentrations (below the crystallize floor)
// render as a negative of the real thing - a lightless black mass that
// drinks the frame instead of glowing - so a forming source can never be
// mistaken for a harvestable cloud.  Fork of arcana_manacloud_ps30; keep the
// marcher in sync with it.
// Volumetric mana concentration.  One screen-quad pass per source: the ray
// through each pixel is marched through a ground-hugging fbm plume that rolls
// and drifts upward, reading as slow luminous gas.  Drawn without depth so it
// shows through walls (mana sight reveals sources, it does not care about
// geometry).
//
// Constants0: xyz = plume base (ground, world), w = radius
// Constants1: xyz = eye position (world),       w = time (wrapped in Lua)
// Constants2: xyz = camera forward,             w = strength (0-1)
// Constants3: xyz = camera right * halfW,       w = halfH (vertical ray scale)
#define BASE     Constants0.xyz
#define RADIUS   Constants0.w
#define EYE      Constants1.xyz
#define TIME     Constants1.w
#define FWD      Constants2.xyz
#define STRENGTH Constants2.w
#define RIGHT_S  Constants3.xyz
#define HALF_H   Constants3.w

#define STEPS 16
#define CLOUD_COL  float3(0.05, 0.04, 0.08)
#define CORE_COL   float3(0.11, 0.09, 0.15)

struct PS_IN { float2 uv : TEXCOORD0; };

float hash3(float3 p)
{
	return frac(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float noise3(float3 p)
{
	float3 i = floor(p);
	float3 f = frac(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);

	float n000 = hash3(i);
	float n100 = hash3(i + float3(1, 0, 0));
	float n010 = hash3(i + float3(0, 1, 0));
	float n110 = hash3(i + float3(1, 1, 0));
	float n001 = hash3(i + float3(0, 0, 1));
	float n101 = hash3(i + float3(1, 0, 1));
	float n011 = hash3(i + float3(0, 1, 1));
	float n111 = hash3(i + float3(1, 1, 1));

	float nx00 = lerp(n000, n100, f.x);
	float nx10 = lerp(n010, n110, f.x);
	float nx01 = lerp(n001, n101, f.x);
	float nx11 = lerp(n011, n111, f.x);

	return lerp(lerp(nx00, nx10, f.y), lerp(nx01, nx11, f.y), f.z);
}

float fbm3(float3 p)
{
	float value = 0.0;
	float amplitude = 0.5;

	for (int i = 0; i < 3; i++)
	{
		value += amplitude * noise3(p);
		p = p * 2.0 + 17.3;
		amplitude *= 0.5;
	}

	return value;
}

// Gas density at world point p, in [0..1].  There is deliberately NO shaped
// envelope (no cone, no teardrop): the form is whatever the domain-warped
// noise condenses into right now, morphing and wandering over time, only
// loosely contained inside the bounding sphere and biased toward the ground.
float density(float3 p)
{
	float3 q = (p - BASE) / RADIUS;

	// Lumpy containment: the boundary radius varies with low-frequency
	// animated noise, so the volume's silhouette is an irregular shifting
	// mass instead of a telltale sphere fade
	float3 c = q - float3(0.0, 0.0, 0.8);
	float edgeN = fbm3(q * 1.1 + float3(TIME * 0.06, 3.7, -TIME * 0.09));
	float contain = saturate(1.0 - dot(c, c) * (0.55 + 0.85 * edgeN));

	if (contain <= 0.0)
	{
		return 0.0;
	}

	// Domain warp: the wandering, curling motion of the mass itself
	float3 warp = float3(
		fbm3(q * 1.3 + float3(TIME * 0.18, 0.0, -TIME * 0.22)),
		fbm3(q * 1.3 + float3(5.2, TIME * 0.15, -TIME * 0.25)),
		fbm3(q * 1.3 + float3(2.7, 8.1, -TIME * 0.30))
	) - 0.5;
	float3 s = q + warp * 1.1;

	// Low-frequency morphing body picks WHERE the gas condenses; finer detail
	// rolls across it
	float body = fbm3(s * 1.6 + float3(0.0, 0.0, -TIME * 0.28));
	float detail = fbm3(s * 4.2 + float3(0.0, 0.0, -TIME * 0.60));
	float d = saturate(body * 1.75 - 0.68 + (detail - 0.5) * 0.55);

	// Ground phenomenon: gently denser in the lower half
	d *= saturate(1.2 - q.z * 0.45);

	return saturate(d * contain * 1.6) * STRENGTH;
}

float4 main(PS_IN i) : COLOR
{
	float3 screenCol = tex2D(TexBase, i.uv).rgb;

	// Per-pixel view ray
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	// Bounding sphere around the plume volume
	float3 volCenter = BASE + float3(0, 0, RADIUS * 0.8);
	float volRadius = RADIUS * 1.5;
	float3 oc = EYE - volCenter;
	float b = dot(oc, dir);
	float disc = volRadius * volRadius - (dot(oc, oc) - b * b);

	if (disc <= 0.0)
	{
		return float4(screenCol, 1.0);
	}

	float sq = sqrt(disc);
	float t0 = max(-b - sq, 0.0);
	float t1 = -b + sq;

	if (t1 <= t0)
	{
		return float4(screenCol, 1.0);
	}

	// March the ray, front to back.  No per-pixel jitter: it reads as grain;
	// the higher step count hides banding instead.
	float stepLen = (t1 - t0) / STEPS;
	float t = t0 + stepLen * 0.5;
	float acc = 0.0;
	float glow = 0.0;
	float filaments = 0.0;

	for (int s = 0; s < STEPS; s++)
	{
		float3 p = EYE + dir * t;
		float d = density(p);
		acc += (1.0 - acc) * d * 0.38;

		// The glow lives where the gas is densest, wherever that happens to be
		glow += d * d * 0.35;

		// Energy filaments: ridged noise threads rising through the gas faster
		// than the body churns, so bright veins snake around inside it
		float3 q = (p - BASE) / RADIUS;
		float n = noise3(q * float3(2.4, 2.4, 1.0) + float3(0.0, 0.0, -TIME * 1.15));
		float ridge = pow(saturate(1.0 - abs(n * 2.0 - 1.0) * 2.1), 5.0);
		filaments += (1.0 - acc) * d * ridge * 0.55;

		t += stepLen;
	}

	acc = saturate(acc);
	glow = saturate(glow);
	filaments = saturate(filaments);

	// Capped below full opacity so the refracted background stays visible
	// through even the densest gas
	float alpha = saturate(acc * 1.8) * 0.9;

	if (alpha <= 0.003)
	{
		return float4(screenCol, 1.0);
	}

	// The gas refracts and colour-splits what lies behind it across its FULL
	// extent: thin veils bend the background slightly, dense cores strongly
	float cover = saturate(acc * 5.0);
	float2 warpUV = float2(
		noise3(float3(i.uv * 37.0, TIME * 0.60)) - 0.5,
		noise3(float3(i.uv * 41.0 + 13.7, TIME * 0.55)) - 0.5
	) * (0.012 + 0.030 * acc) * cover;
	// Mild per-channel split: the gas distorts what lies behind it, and any
	// fringing stays subtle so it reads inside the panel's own palette
	// instead of introducing raw out-of-palette colours
	float3 refr;
	refr.r = tex2D(TexBase, i.uv + warpUV * 1.15).r;
	refr.g = tex2D(TexBase, i.uv + warpUV).g;
	refr.b = tex2D(TexBase, i.uv + warpUV * 0.85).b;
	screenCol = lerp(screenCol, refr, cover);

	// Negative body: near-black veils with the faintest violet cast, thread
	// veins as slightly-less-dark seams rather than light
	float rim = saturate(acc * 4.0) * (1.0 - saturate(acc * 1.6));
	float3 cloudCol = lerp(CLOUD_COL, CORE_COL, glow);
	cloudCol = lerp(cloudCol, float3(0.14, 0.12, 0.20), rim * 0.85);
	cloudCol += float3(0.10, 0.09, 0.14) * filaments * 0.9;

	float3 col = lerp(screenCol, cloudCol, alpha);

	// Anti-light: dense cores drink what remains of the frame instead of
	// pushing past it
	col -= col * (glow * 0.35 + filaments * 0.2) * alpha;

	return float4(col, 1.0);
}
