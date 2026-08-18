#include "common.hlsl"

// Crystallization whorl: a pure SCREEN-SPACE distortion pass drawn over the
// channeled mana cloud.  The cloud (and the lightning arcs drawn before this
// pass) render untouched; this twists the already-rendered frame around the
// source's projection - per-channel, so the twist fringes chromatically -
// pulls it gently inward, and lays faint spiral filaments along the twist.
// The twist has NO time-driven rotation: it is a static warp that winds
// tighter as the channel fraction rises.
//
// All inputs are precomputed in Lua (screen space), which frees a register
// for the lens window's inscribed box: twisted samples are CLAMPED into it,
// so the whorl can never drag ungraded colours from outside the lens.
//
// Constants0: xy = source centre (ndc), z = halfW, w = halfH
// Constants1: x = 1 / angular radius, y = channel fraction, z = time
// Constants2: xy = sample clamp min (uv), zw = sample clamp max (uv)

#define C_NDC     Constants0.xy
#define HALF_W    Constants0.z
#define HALF_H    Constants0.w
#define INV_R     Constants1.x
#define CRYST     Constants1.y
#define TIME      Constants1.z
#define CLAMP_MIN Constants2.xy
#define CLAMP_MAX Constants2.zw

struct PS_IN { float2 uv : TEXCOORD0; };

float hash2(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float noise2(float2 p)
{
	float2 i = floor(p);
	float2 f = frac(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = hash2(i);
	float b = hash2(i + float2(1, 0));
	float c = hash2(i + float2(0, 1));
	float d = hash2(i + float2(1, 1));

	return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float4 main(PS_IN i) : COLOR
{
	float3 screenCol = tex2D(TexBase, i.uv).rgb;

	// This pixel's angular offset from the centre, normalized to the
	// source's apparent radius
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float ax = (ndc.x - C_NDC.x) * HALF_W;
	float ay = (ndc.y - C_NDC.y) * HALF_H;
	float rr = length(float2(ax, ay)) * INV_R;

	if (rr >= 1.0)
	{
		return float4(screenCol, 1.0);
	}

	float theta = atan2(ay, ax);

	// Twist profile: strongest at the core, exactly zero at the rim (so the
	// edge is seamless), winding up quadratically with the channel
	float fall = pow(1.0 - rr, 1.6);
	float twist = CRYST * CRYST * 22.0 * fall;
	float suck = 1.0 + CRYST * 0.5 * fall;

	// Re-sample the frame through the twist, each channel wound slightly
	// differently: chromatic fringes along every warped feature.  Samples are
	// clamped into the lens window so the whorl never reads past its edge.
	float3 col;

	for (int ch = 0; ch < 3; ch++)
	{
		float t = theta + twist * (0.88 + 0.12 * ch);
		float r = rr * suck / INV_R;
		float2 n = float2(C_NDC.x + cos(t) * r / HALF_W, C_NDC.y + sin(t) * r / HALF_H);
		float2 uv = float2((n.x + 1.0) * 0.5, (1.0 - n.y) * 0.5);
		float3 s = tex2D(TexBase, clamp(uv, CLAMP_MIN, CLAMP_MAX)).rgb;
		col[ch] = s[ch];
	}

	// Faint spiral filaments riding the twist, wavering slightly so they read
	// hand-drawn; brightening as the whorl tightens.  The wobble noise is fed
	// POSITION, not theta: a theta-based input is discontinuous across the
	// atan2 seam (the +-pi ray) and drew a hard line out of the centre.
	float wob = (noise2(float2(ax, ay) * (5.0 * INV_R) + TIME * 0.15) - 0.5) * 0.4;
	float phase = theta + twist + (rr + wob) * 18.0;
	float fil = pow(saturate(cos(phase)), 14.0);
	col += float3(1.1, 1.0, 0.8) * fil * CRYST * fall * 0.7;

	return float4(col, 1.0);
}
