#include "common.hlsl"

// ---------------------------------------------------------------------------
// The mana box: a hollow frosted-glass cube held in the palm, a near-opaque
// dark slab while dormant.  Everything is analytic in BOX-LOCAL space (the
// cube spans [-1,1] on each axis, see arcana_manabox_vs30):
//
//   * the ray from the eye through the shaded point is traced to the far wall
//     of the cube, and that wall's centred glow is what shows through the
//     pane.  Three walls are visible at once, so their glows read as the
//     nested rounded squares of the reference model, and the cavity's inner
//     edges draw themselves as brighter lines where the ray exits near a
//     corner.
//   * frost is 3D value noise contoured into ripples, so it lives on the glass
//     surface instead of swimming in screen space.
// ---------------------------------------------------------------------------

#define EYE_LOCAL    Constants0.xyz  // eye position in box-local units
#define TIME         Constants0.w
#define GLOW         Constants1.x    // interior light intensity (pulses)
#define FILL         Constants1.y    // 0..1, how charged the box is
#define ACTIVE       Constants1.z    // 0 = dormant gray stone box, 1 = panel live
#define FROST        Constants1.w    // surface scatter amount
#define TINT         Constants2.rgb  // glass colour (Lua lerps dark gray -> panel blue)
#define EDGE_GAIN    Constants3.w

struct PS_IN
{
	float2 uv      : TEXCOORD0;
	float4 color   : TEXCOORD1;
	float3 normal  : TEXCOORD2;
	float3 lpos    : TEXCOORD3;
};

float hash31(float3 p)
{
	p = frac(p * 0.3183099 + float3(0.71, 0.113, 0.419));
	p *= 17.0;
	return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise3(float3 p)
{
	float3 i = floor(p);
	float3 f = frac(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash31(i + float3(0, 0, 0));
	float n100 = hash31(i + float3(1, 0, 0));
	float n010 = hash31(i + float3(0, 1, 0));
	float n110 = hash31(i + float3(1, 1, 0));
	float n001 = hash31(i + float3(0, 0, 1));
	float n101 = hash31(i + float3(1, 0, 1));
	float n011 = hash31(i + float3(0, 1, 1));
	float n111 = hash31(i + float3(1, 1, 1));

	float x00 = lerp(n000, n100, f.x);
	float x10 = lerp(n010, n110, f.x);
	float x01 = lerp(n001, n101, f.x);
	float x11 = lerp(n011, n111, f.x);

	return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
}

float fbm3(float3 p)
{
	return noise3(p) * 0.62 + noise3(p * 2.17) * 0.26 + noise3(p * 4.31) * 0.12;
}

// Contoured frost: the noise field sliced into bands, like the rippled sheet
// glass of the reference model
float frostRipple(float3 p)
{
	float w = fbm3(p * 3.4);
	float r = 0.5 + 0.5 * sin(w * 26.0 + fbm3(p * 8.5) * 3.0);

	return r * r;
}

float4 main(PS_IN i) : COLOR
{
	float3 n = normalize(i.normal);
	float3 ro = i.lpos;
	float3 rd = normalize(ro - EYE_LOCAL);
	float3 toEye = -rd;

	// -----------------------------------------------------------------------
	// Glass: trace to the far wall of the cavity
	// -----------------------------------------------------------------------
	// Dormant, the frost is frozen in place; live, it drifts and energy
	// currents wash across every face
	float tA = TIME * ACTIVE;
	float ripple = frostRipple(ro + float3(0.0, 0.0, tA * 0.2));

	// The cube spans [-1,1]: noise below ~5x has features bigger than the box
	// and reads as static, so the currents run fine and fast
	float cw = fbm3(ro * 6.0 + tA * float3(1.6, 1.1, 2.0))
	         + fbm3(ro * 10.0 - tA * float3(1.0, 1.9, 1.3));
	float caustic = pow(saturate(0.5 + 0.5 * sin(cw * 9.0 - tA * 5.0)), 3.0) * ACTIVE;
	// Darting filaments: knife-thin ridges of the same field, racing across
	// the panes much faster than the caustic wash underneath
	float fil = pow(1.0 - abs(frac(cw * 2.0 - tA * 2.2) * 2.0 - 1.0), 9.0) * ACTIVE;

	// Interior light: neutral when dormant, the panel's hologram white-blue live
	float3 core = lerp(float3(0.8, 0.8, 0.8), float3(0.8, 0.92, 1.08), ACTIVE);

	// Frost scatters the ray a little, so the interior bands wobble instead of
	// projecting like a clean lens
	float3 jitter = float3(fbm3(ro * 5.1 + 11.3), fbm3(ro * 5.1 + 27.7), fbm3(ro * 5.1 + 41.9)) - 0.5;
	float3 srd = normalize(rd + jitter * FROST);

	float3 sgn = sign(srd);
	sgn = lerp(float3(1, 1, 1), sgn, abs(sgn));
	float3 inv = sgn / max(abs(srd), 1e-4);

	float3 tFar = (sgn - ro) * inv;
	float3 tNear = (-sgn - ro) * inv;
	float tE = min(tFar.x, min(tFar.y, tFar.z));
	float tN = max(tNear.x, max(tNear.y, tNear.z));
	float chord = max(tE - tN, 0.0);

	float3 pe = ro + srd * tE;

	// Drop the exit face's own axis: what is left are the coordinates ON that
	// wall, so the glow is centred per wall
	float3 a = abs(pe);
	float3 q = pe;
	if (a.x >= a.y && a.x >= a.z) q.x = 0.0;
	else if (a.y >= a.z) q.y = 0.0;
	else q.z = 0.0;

	float d2 = dot(q, q);
	float lit = exp(-1.55 * d2);

	// Softly stepped, the way light layers through stacked frosted sheets
	float st = lit * 5.0;
	float litQ = (floor(st) + smoothstep(0.3, 0.7, frac(st))) / 5.0;
	lit = lerp(lit, litQ, 0.55);

	// Inner cavity edges: the ray leaving near a wall corner picks up the seam
	float m = max(abs(q.x), max(abs(q.y), abs(q.z)));
	float seam = smoothstep(0.82, 0.995, m) * EDGE_GAIN;

	float haze = saturate(chord / 2.55);
	// abs(): the same panes are rasterized from inside in the far cull pass,
	// where dot(n, toEye) goes negative and a naive fresnel saturates to 1,
	// lighting interior walls up like full faces
	float ndv = abs(dot(n, toEye));
	float fres = pow(1.0 - saturate(ndv), 3.0);

	// Interior walls recede: seen through the frosted front pane they keep a
	// hint of shading but none of the face dressing, or they read as extra
	// cube faces floating where none should be
	float front = (dot(n, toEye) >= 0.0) ? 1.0 : 0.0;
	float backFade = lerp(0.35, 1.0, front);

	// Polished pane border: light piped through the pane's own thickness
	float2 e = min(i.uv, 1.0 - i.uv);
	float border = (1.0 - smoothstep(0.0, 0.055, min(e.x, e.y))) * lerp(0.1, 1.0, front);

	float inner = saturate(lit * GLOW * (0.45 + 0.55 * FILL));

	float3 glassCol = lerp(TINT, core, inner);
	glassCol = lerp(glassCol, core * 1.06, seam * 0.55);
	glassCol = lerp(glassCol, core * 0.9, haze * 0.32);
	glassCol *= 0.9 + 0.2 * ripple;
	glassCol += core * (caustic * 1.1 + fil * 1.3) * backFade;
	glassCol = lerp(glassCol, TINT * 1.12, border * 0.8);
	glassCol = lerp(glassCol, TINT * 1.18, fres * 0.45);

	float glassA = saturate(0.40 + 0.42 * fres + 0.5 * border + 0.3 * inner + 0.12 * ripple + 0.25 * seam + 0.35 * caustic + 0.4 * fil) * backFade;

	// Dormant the box is a near-opaque dark slab (TINT is dark gray then):
	// frozen frost relief, a hint of rim light, none of the live translucency
	float3 idleCol = TINT * (0.75 + 0.3 * ripple) + TINT * fres * 0.5;

	float3 col = lerp(idleCol, glassCol, ACTIVE);
	float alpha = lerp(0.94 * backFade, glassA, ACTIVE) * i.color.a;

	return float4(col, alpha);
}
