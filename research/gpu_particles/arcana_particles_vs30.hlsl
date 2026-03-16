#include "common_vs.hlsl"

// Use ambient cube hack to get time into vertex shader (from shader guide Example 6)
// Proper Source Engine definition from common_vs_fxc.h:
const float3 cAmbientCubeX[2] : register(c21);
const float3 cAmbientCubeY[2] : register(c23);
const float3 cAmbientCubeZ[2] : register(c25);

// Ambient cube data
#define CURRENT_TIME cAmbientCubeX[0].x
#define LIFETIME cAmbientCubeX[0].y
#define PARTICLE_SIZE cAmbientCubeX[0].z
#define END_SIZE cAmbientCubeX[1].x  // End size from second cube slot
#define START_ALPHA cAmbientCubeX[1].y  // Start alpha (0-1)
#define END_ALPHA cAmbientCubeX[1].z  // End alpha (0-1)

struct VS_INPUT_PARTICLE
{
	float4 pos          : POSITION;   // x = particle ID, yz = quad corner offset
	float4 uv           : TEXCOORD0;  // x = birth time, y = roll delta, z = unused
	float4 color        : COLOR0;     // rgba = base color
	float4 normal       : NORMAL;     // xyz = initial velocity
	float4 tangent      : TANGENT;    // xy = quad UV, z = lifetime multiplier, w = initial roll
};

struct VS_OUTPUT_PARTICLE
{
	float4 projPos      : POSITION;
	float2 uv           : TEXCOORD0;  // xy = quad UV for texture sampling
	float4 color        : TEXCOORD1;
};

// Simple hash function for pseudo-random numbers
float hash(float n)
{
	return frac(sin(n) * 43758.5453123);
}

float hash2D(float2 p)
{
	return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float3 hash3D(float n)
{
	return float3(
		hash(n),
		hash(n + 1.57),
		hash(n + 3.14)
	);
}

VS_OUTPUT_PARTICLE main(VS_INPUT_PARTICLE i)
{
	VS_OUTPUT_PARTICLE o;

	// Extract particle data from vertex attributes
	float particleID = i.pos.x;
	float2 quadUV = i.tangent.xy;  // Quad UVs from tangent.xy
	float birthTime = i.uv.x;  // Birth time
	float rollDelta = i.uv.y;  // Roll delta (rotation speed in deg/sec)
	float3 initialVel = i.normal.xyz;  // Velocity
	float lifetimeMult = i.tangent.z;  // Lifetime multiplier
	float initialRoll = i.tangent.w;  // Initial rotation angle (degrees)

	// Spawn at local origin (0,0,0) - the model matrix will position us correctly
	float3 spawnPos = float3(0, 0, 0);

	// Calculate particle age
	float totalAge = CURRENT_TIME - birthTime;  // Total age (never resets)
	float maxLifetime = LIFETIME * lifetimeMult;

	// Loop particles for physics/life calculations
	float age = fmod(totalAge, maxLifetime);
	if (age < 0.0) age += maxLifetime;

	// Normalized life (0 = birth, 1 = death)
	float normalizedLife = saturate(age / maxLifetime);

	// Random offset for this particle
	float3 randomOffset = hash3D(particleID) * 2.0 - 1.0;
	float3 spawnOffset = randomOffset * 25.0;  // 25 unit spawn radius

	// Physics simulation with air resistance
	// Air resistance: velocity decays exponentially over time
	// v(t) = v0 * exp(-k * t) where k is air resistance coefficient
	// For integration: position = v0/k * (1 - exp(-k*t))
	float airResistance = 40.0; // Hardcoded for now (matches brazier config)
	float k = airResistance * 0.01; // Scale down for reasonable decay

	// Velocity with air resistance (exponential decay)
	float velocityScale = (k > 0.001) ? ((1.0 - exp(-k * age)) / k) : age;
	float3 worldPos = spawnPos + spawnOffset;
	worldPos += initialVel * velocityScale;

	// Gravity (also affected by air resistance in real physics, but simplified here)
	float3 gravity = float3(0, 0, 15);
	worldPos += gravity * 0.5 * age * age;

	// Interpolate size from start to end over lifetime
	float startSize = PARTICLE_SIZE;
	float endSize = END_SIZE;
	float particleSize = lerp(startSize, endSize, normalizedLife);

	// Apply fade in/out curve
	float fadeCurve = sin(normalizedLife * 3.14159);
	particleSize *= fadeCurve;

	// Calculate current rotation angle (degrees to radians)
	// Use totalAge (not looped age) so rotation continues across particle respawns
	// GMod's SetRollDelta might actually be radians/sec, not degrees/sec - multiply by ~57.3 to match
	float currentRoll = initialRoll + rollDelta * totalAge * 57.2958;  // Convert radians to degrees
	float rollRad = currentRoll * 0.0174533;  // Convert to radians

	// Pre-calculate sin/cos for billboard rotation
	float cosR = cos(rollRad);
	float sinR = sin(rollRad);

	// Rotate the quad offset by the roll angle
	float2 quadOffset = float2(i.pos.y, i.pos.z);
	float2 rotatedQuadOffset = float2(
		quadOffset.x * cosR - quadOffset.y * sinR,
		quadOffset.x * sinR + quadOffset.y * cosR
	);

	// World-space billboarding: extract camera right/up from view matrix
	// cViewProj is view*projection, so we need to extract view vectors
	// Camera right is first row of inverse view, camera up is second row
	float3 cameraRight = normalize(float3(cViewProj[0][0], cViewProj[1][0], cViewProj[2][0]));
	float3 cameraUp = normalize(float3(cViewProj[0][1], cViewProj[1][1], cViewProj[2][1]));

	// Apply rotated billboard offset in world space
	float3 billboardPos = worldPos + (cameraRight * rotatedQuadOffset.x + cameraUp * rotatedQuadOffset.y) * particleSize;

	// Transform final position to clip space
	float4 clipPos = mul(float4(billboardPos, 1.0), cModelViewProj);

	o.projPos = clipPos;

	// Pass quad UVs for texture sampling (no rotation on UVs, just the quad itself rotates)
	o.uv = quadUV;

	// Interpolate alpha from start to end over lifetime
	float alpha = lerp(START_ALPHA, END_ALPHA, normalizedLife);

	// Apply fade in/out curve to alpha as well
	alpha *= fadeCurve;

	o.color = i.color;
	o.color.a = alpha;

	return o;
}
