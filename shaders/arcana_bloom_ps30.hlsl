#include "common.hlsl"

// Constants0: x = blur direction X (1 or 0), y = blur direction Y (0 or 1), z = radius scale (texels)
// Constants1: x = bloom intensity multiplier, y = chromatic aberration strength (0 = off)
// Constants2: x = snapshot-diff mode (1 = output max($basetexture - $texture1, 0)),
//             y = daylight boost — scales the captured contribution with
//                 background luminance (0 = off)
//             z = dark-colour boost cap — max perceptual equalisation factor
//                 for low-luminance hues like purple/deep green (1 = off)
#define DIR_X          Constants0.x
#define DIR_Y          Constants0.y
#define RADIUS         Constants0.z
#define INTENSITY      Constants1.x
#define CA_STRENGTH    Constants1.y
#define DIFF_MODE      Constants2.x
#define DAYLIGHT_BOOST Constants2.y
#define DARK_BOOST_CAP Constants2.z

struct PS_IN { float2 uv : TEXCOORD0; };

// Normalised 9-tap Gaussian weights (sigma ~2.0)
// Sum of all weights = W[0] + 2*(W[1]+W[2]+W[3]+W[4]) = 1.0
static const float W[5] = {
	0.2270270270,
	0.1945945946,
	0.1216216216,
	0.0540540541,
	0.0162162162
};

// Clamp UV to a half-texel inset so bilinear filtering never bleeds across
// the texture border into the opposite edge (which causes wrap-around bloom).
#define SAMPLE(uv) tex2D(TexBase, clamp((uv), TexBaseSize * 0.5, 1.0 - TexBaseSize * 0.5))

float4 main(PS_IN i) : COLOR
{
	// Snapshot-diff mode: isolate the circles' visible screen contribution as
	// max(after - before, 0).  Both snapshots are sampled by this same draw,
	// so HDR tonemap scaling and blend state apply to both terms identically
	// and cancel out exactly (a blend-op subtract cannot guarantee that).
	if (DIFF_MODE > 0.5)
	{
		float3 before = tex2D(Tex1, i.uv).rgb;
		float3 diff = max(tex2D(TexBase, i.uv).rgb - before, float3(0.0, 0.0, 0.0));

		// Bright backgrounds swallow the circles' blended contribution, and
		// the screen-blend composite attenuates it again — so daylight scenes
		// barely bloom.  Compensate by scaling the contribution with the
		// background luminance; dark scenes (luma ~0) are unaffected.
		float bgLuma = dot(before, float3(0.2126, 0.7152, 0.0722));
		diff *= 1.0 + DAYLIGHT_BOOST * bgLuma;

		// Perceptual equalisation: dark or saturated-dark hues (purple, deep
		// green) add little luminance and would barely bloom.  Normalise by
		// the contribution's own luma so hue drives the glow, not brightness.
		// Applied here, per-pixel before the blur dilutes the signal (this
		// replaces the old weaker version that ran in the composite pass).
		float luma = dot(diff, float3(0.2126, 0.7152, 0.0722));
		diff *= clamp(pow(max(luma, 0.001), -0.45), 1.0, max(DARK_BOOST_CAP, 1.0));

		return float4(diff, 1.0);
	}

	// TexBaseSize = (1/srcWidth, 1/srcHeight), provided by screenspace_general via common.hlsl c4
	float2 step = float2(DIR_X, DIR_Y) * TexBaseSize * max(1.0, RADIUS);

	float4 col = SAMPLE(i.uv         ) * W[0];

	col += SAMPLE(i.uv + step * 1) * W[1];
	col += SAMPLE(i.uv - step * 1) * W[1];
	col += SAMPLE(i.uv + step * 2) * W[2];
	col += SAMPLE(i.uv - step * 2) * W[2];
	col += SAMPLE(i.uv + step * 3) * W[3];
	col += SAMPLE(i.uv - step * 3) * W[3];
	col += SAMPLE(i.uv + step * 4) * W[4];
	col += SAMPLE(i.uv - step * 4) * W[4];

	// Chromatic aberration — active only in the composite pass (CA_STRENGTH > 0).
	// Applied before perceptual boost and intensity so all three channels receive
	// the same uniform scaling afterwards.  Red is pushed outward from the screen
	// centre, blue inward, creating the classic lens-fringe split on bloom edges.
	// The effect grows with distance from the screen centre so it is strongest at
	// the corners, just like a real lens.
	if (CA_STRENGTH > 0.001) {
		float2 dir = i.uv - float2(0.5, 0.5);
		col.r = SAMPLE(i.uv + dir * CA_STRENGTH).r;
		col.b = SAMPLE(i.uv - dir * CA_STRENGTH).b;
	}

	// (Perceptual equalisation for dark colours now happens in the snapshot
	// diff pass above, per-pixel before the blur — not here.)

	float intensity = INTENSITY > 0.001 ? INTENSITY : 2.0;
	col.rgb *= intensity;

	// Composite passthrough only (dir = 0): the pipeline works in linear light
	// but the screen framebuffer is gamma-encoded — re-encode on the way out or
	// the halo's small linear values get displayed ~4-6x darker than intended.
	// Blur passes (dir != 0) write to linear-read RTs and must stay linear.
	if (DIR_X + DIR_Y < 0.5) {
		col.rgb = pow(max(col.rgb, 0.0), 0.4545);
	}

	// Force full alpha so the additive composite uses the full RGB contribution
	// regardless of what alpha the source texture had.
	col.a = 1.0;

	return col;
}