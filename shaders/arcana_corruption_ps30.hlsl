#include "common.hlsl"

// Corrupted-area screenspace effect.  The sphere is computed analytically per
// pixel (no stencil silhouette): the interior gets the corruption grading
// (desaturate/contrast/darken + refraction), and the boundary is a flame ring
// — a hot glowing line hugging the noise-warped silhouette with tapering
// tongues licking outward, over a darkened rim.  Drawn as a screen quad
// inside an EXPANDED stencil sphere (world occlusion + cull only).
//
// Constants0: xyz = sphere centre (world), w = sphere radius
// Constants1: xyz = eye position (world),  w = time (wrapped in Lua)
// Constants2: xyz = camera forward,        w = raw intensity (0-2)
// Constants3: xyz = camera right * tan(fov/2), w = vertical ray scale
#define CENTER    Constants0.xyz
#define RADIUS    Constants0.w
#define EYE       Constants1.xyz
#define TIME      Constants1.w
#define FWD       Constants2.xyz
#define INTENSITY Constants2.w
#define RIGHT_S   Constants3.xyz
#define HALF_H    Constants3.w

// Boundary shaping, in fractions of the sphere radius.  The stencil sphere in
// arcana_corrupted_area.lua is expanded by STENCIL_EXPAND = 1.4 — keep
// LICK_LEN + (EDGE_BIG + EDGE_AMP) * 0.5 below that expansion.
#define EDGE_BIG 0.11 // low-frequency "puff" warp of the silhouette (big lobes)
#define EDGE_AMP 0.05 // fine-detail warp on top
#define LICK_LEN 0.18 // how far flame tongues reach outside

// Flame colour: near-black with a hint of purple — the tongues read as dark
// silhouettes licking over the sky/world
#define FLAME_COLOR float3(0.015, 0.005, 0.02)

struct PS_IN { float2 uv : TEXCOORD0; };

// 3D value noise (sin-based hash: no axis-aligned correlation artifacts)
float hash3(float3 p)
{
	return frac(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float noise3(float3 p)
{
	float3 i = floor(p);
	float3 f = frac(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0); // quintic: smoother cells

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

float4 main(PS_IN i) : COLOR
{
	float3 screenCol = tex2D(TexBase, i.uv).rgb;

	// Intensity ramps.  STRENGTH drives the grading (the old Lua smoothstep
	// remap of intensity 0.5..2 -> 0..1, moved here); flameScale keeps the
	// flames invisible until intensity 1.25, fully black at 2.
	float s0 = saturate((INTENSITY - 0.5) / 1.5);
	float sSm = s0 * s0 * (3.0 - 2.0 * s0);
	float STRENGTH = saturate(0.5 * (s0 + sSm) + 0.08);
	float flameScale = saturate((INTENSITY - 1.25) / 0.75);

	// Per-pixel view ray from the camera basis
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	// Ray/sphere distance field: edge < 0 inside the silhouette, > 0 outside,
	// in radius units.  anchor = world-stable noise coordinate on the sphere:
	// the ray's ENTRY point when it hits (stable across the whole interior —
	// the closest-approach point degenerates at the silhouette centre and
	// caused radial streaks), the closest-approach point when it misses.
	float3 oc = EYE - CENTER;
	float distSq = dot(oc, oc);
	float rr = RADIUS * RADIUS;
	float b = dot(oc, dir); // -(distance to closest approach)
	float edge;
	float3 anchor;
	bool eyeInside = distSq < rr;

	if (eyeInside)
	{
		// Anchor on the EXIT point: the sphere wall being looked at from within
		float disc = rr - (distSq - b * b);
		edge = -1.0;
		anchor = normalize((EYE + dir * (-b + sqrt(disc))) - CENTER);
	}
	else
	{
		// Sphere entirely behind this ray (prevents the boundary effect
		// mirroring onto the opposite side of the screen when standing close)
		if (b > 0.0)
		{
			return float4(screenCol, 1.0);
		}

		float closestSq = max(distSq - b * b, 0.0);
		float disc = rr - closestSq;
		edge = sqrt(closestSq) / RADIUS - 1.0;

		if (disc > 0.0)
		{
			// Ray hits: anchor on the front surface
			anchor = normalize((EYE + dir * (-b - sqrt(disc))) - CENTER);
		}
		else
		{
			// Ray misses: closest approach (well-defined near the silhouette)
			anchor = normalize((EYE - dir * b) - CENTER);
		}
	}

	// Animated surface noise: slow upward drift + a light sideways flicker.
	// The lower z frequency stretches the features vertically → taller,
	// flame-like tongues instead of round blobs.  Fbig is a low-frequency
	// layer that deforms the silhouette in big soft lobes ("puffiness");
	// F adds the fine flame detail on top.
	float3 drift = float3(TIME * 0.07, 0.0, -TIME * 0.30);
	float Fbig = fbm3(anchor * 2.2 + drift * 0.7);
	float F = fbm3(anchor * float3(6.0, 6.0, 2.2) + drift);
	float veins = fbm3(anchor * 3.0 + drift * 0.5 + 31.4);

	// Noise-warped boundary coordinate
	float w = edge + (0.5 - Fbig) * EDGE_BIG + (0.5 - F) * EDGE_AMP;

	// Spatial coverage of the volume (inside the warped silhouette), kept
	// separate from the intensity ramps so the full footprint shows even at
	// low intensity while the effects scale within it
	float cover = 1.0 - smoothstep(-0.06, 0.02, w);

	// Flame ring: core line ON the boundary + tongues in a thin shell around
	// it (the shell envelope keeps the interior clean — without it the tongue
	// term stays active across the whole sphere)
	float ringCore = 1.0 - smoothstep(0.0, 0.06, abs(w));
	// Shell reaches LICK_LEN outward AND overlaps the dome inward, so the
	// flames visibly wrap over the corruption sphere instead of only licking
	// into the sky
	float shell = (1.0 - smoothstep(0.0, LICK_LEN, w)) * smoothstep(-0.20, -0.05, w);
	float puff = pow(saturate(Fbig * 1.8 - 0.5), 1.3);
	float detail = pow(saturate(F * 1.7 - 0.55), 1.3);
	float tongues = shell * saturate(puff * 1.5 + detail * 0.6);
	float flame = saturate(ringCore * 0.85 + tongues);

	// $texture1, built with stencils against the real depth buffer in Lua and
	// blurred: r = "world surface inside the sphere" coverage, g = "sphere
	// front surface visible" coverage.  Used only to end the dome at the
	// world intersection — no flames are drawn along it.
	float2 mask = tex2D(Tex1, i.uv).rg;

	// Shape the flame alpha: solid near the core but with a soft smoky
	// falloff at the blob edges (a hard threshold here reads as crisp
	// cut-out shapes instead of smoke)
	flame = smoothstep(0.05, 0.65, flame) * flameScale;

	// Where the world hides the sphere's front surface (foreground ground in
	// front of the buried half), the dome must visually END at the
	// intersection: suppress grading and flames there.  A sphere bottom
	// genuinely visible from below (cliffs) has g = 1 and is unaffected.
	float visMask = smoothstep(0.12, 0.4, max(mask.g, mask.r));
	cover *= visMask;
	flame *= visMask;

	if (cover <= 0.003 && flame <= 0.003)
	{
		return float4(screenCol, 1.0);
	}

	// Distortion and grayscale ramp LINEARLY across the whole intensity range
	// (start at 0.5, max at 2); contrast/darken keep the smoothed STRENGTH
	// curve.  All spatially masked by cover.
	float ramp = saturate((INTENSITY - 0.5) / 1.5);
	float grading = STRENGTH * cover;

	// Interior grading (replaces DrawColorModify + water_warp).  The
	// refraction is much heavier when looking at the volume from outside
	// (the dome churns hard) and moderate while standing within it.
	float warpAmp = eyeInside ? 0.045 : 0.10;
	float2 warp = (float2(F, veins) - 0.5) * warpAmp * ramp * cover;
	float3 col = tex2D(TexBase, i.uv + warp).rgb;

	float grey = dot(col, float3(0.299, 0.587, 0.114));
	col = lerp(col, float3(grey, grey, grey), saturate(1.1 * ramp) * cover);
	col = (col - 0.5) * (1.0 + grading) + 0.5 - 0.04 * grading;

	// Dark rolling veins for relief, subtle across the interior
	col *= 1.0 - saturate(veins - 0.35) * grading * 0.5;

	// Dark rim just inside the boundary: cloud-modulated so it reads as
	// irregular smoke hugging the edge, not a uniform black band
	float rim = (1.0 - smoothstep(0.0, 0.28, abs(w))) * smoothstep(0.10, -0.04, w);
	rim *= 0.35 + 0.85 * Fbig;
	col *= 1.0 - saturate(rim) * 0.65 * STRENGTH;

	// Rising pattern on the sphere wall: tall smoky wisps in surface
	// coordinates scrolling from the bottom toward the top pole.  Anchored to
	// the surface point, so it parallaxes with the sphere and shows from
	// inside too (the anchor is the exit point there).
	float wisp = fbm3(anchor * float3(7.0, 7.0, 1.6) + float3(0.0, 0.0, -TIME * 0.5));
	wisp = pow(saturate(wisp * 1.9 - 0.75), 2.0) * saturate(1.0 - anchor.z * 0.85);
	col = lerp(col, FLAME_COLOR, saturate(wisp * 0.55) * STRENGTH);

	// Composite the graded interior over the screen, then lay the black
	// flames on top
	col = lerp(screenCol, col, saturate(cover));
	col = lerp(col, FLAME_COLOR, flame);

	return float4(col, 1.0);
}
