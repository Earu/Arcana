	#include "common.hlsl"

	// Constants0: x = blur direction X (1 or 0), y = blur direction Y (0 or 1), z = radius scale (texels)
	// Constants1: x = bloom intensity multiplier, y = chromatic aberration strength (0 = off)
	#define DIR_X       Constants0.x
	#define DIR_Y       Constants0.y
	#define RADIUS      Constants0.z
	#define INTENSITY   Constants1.x
	//#define CA_STRENGTH Constants1.y

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

		// Perceptual equalisation: dark-appearing colours (e.g. blues) have a low
		// Rec.709 luminance and bloom dimmer at the same RGB value.  Apply the
		// correction only during the composite passthrough (DIR_X = DIR_Y = 0) so
		// it runs exactly once instead of compounding across every blur pass.
		if (DIR_X + DIR_Y < 0.5) {
			float luma = dot(col.rgb, float3(0.2126, 0.7152, 0.0722));
			float perceptualBoost = clamp(pow(max(luma, 0.001), -0.35), 1.0, 2.5);
			col.rgb *= perceptualBoost;
		}

		float intensity = INTENSITY > 0.001 ? INTENSITY : 2.0;
		col.rgb *= intensity;

		// Force full alpha so the additive composite uses the full RGB contribution
		// regardless of what alpha the source texture had.
		col.a = 1.0;

		// Chromatic aberration — active only in the composite pass (CA_STRENGTH > 0).
		// Red is pushed outward from the screen centre, blue inward, creating the
		// classic lens-fringe split on the bloom/glow edges.  The effect grows with
		// distance from the screen centre so it is strongest at the corners, just
		// like a real lens.
		/*if (CA_STRENGTH > 0.001) {
			float2 dir = i.uv - float2(0.5, 0.5);
			col.r = SAMPLE(i.uv + dir * CA_STRENGTH).r * intensity;
			col.b = SAMPLE(i.uv - dir * CA_STRENGTH).b * intensity;
		}*/

		return col;
	}
