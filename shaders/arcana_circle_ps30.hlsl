#include "common.hlsl"

// Constants0: x = time for noise animation
// Constants1: xyz = color tint (0-1)
#define TIME    Constants0.x
#define COLOR_R Constants1.x
#define COLOR_G Constants1.y
#define COLOR_B Constants1.z

struct PS_IN
{
	float2 uv        : TEXCOORD0;
	float4 color     : TEXCOORD1;
	float2 pos       : VPOS;
};

// Simple 2D noise function
float hash(float2 p)
{
	p = frac(p * float2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return frac(p.x * p.y);
}

float noise(float2 p)
{
	float2 i = floor(p);
	float2 f = frac(p);

	// Smoothstep for smoother interpolation
	f = f * f * (3.0 - 2.0 * f);

	float a = hash(i);
	float b = hash(i + float2(1.0, 0.0));
	float c = hash(i + float2(0.0, 1.0));
	float d = hash(i + float2(1.0, 1.0));

	return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// Fractal noise for more detail
float fbm(float2 p)
{
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;

	for (int i = 0; i < 3; i++)
	{
		value += amplitude * noise(p * frequency);
		frequency *= 2.0;
		amplitude *= 0.5;
	}

	return value;
}

float4 main(PS_IN i) : COLOR
{
	// Calculate pixel size for neighbor sampling
	float2 pixelSize = TexBaseSize;

	// Multi-sample the texture for smoother edges (reduce pixelation)
	// Sample center and 4 neighbors, then average for antialiasing
	float4 center = tex2D(TexBase, i.uv);
	float4 up = tex2D(TexBase, i.uv + float2(0, pixelSize.y * 0.5));
	float4 down = tex2D(TexBase, i.uv - float2(0, pixelSize.y * 0.5));
	float4 left = tex2D(TexBase, i.uv - float2(pixelSize.x * 0.5, 0));
	float4 right = tex2D(TexBase, i.uv + float2(pixelSize.x * 0.5, 0));

	// Average the samples for smooth edges
	float4 texSample = (center * 2.0 + up + down + left + right) / 6.0;

	// Sample neighboring pixels to fill gaps and smooth edges
	float alpha = texSample.a;

	// Only fill gaps if pixel has SOME alpha (not completely transparent)
	// This prevents bleeding outside the circle content
	if (alpha > 0.05 && alpha < 0.5)
	{
		// Sample 4 neighbors (cross pattern)
		float alphaUp = tex2D(TexBase, i.uv + float2(0, pixelSize.y)).a;
		float alphaDown = tex2D(TexBase, i.uv - float2(0, pixelSize.y)).a;
		float alphaLeft = tex2D(TexBase, i.uv - float2(pixelSize.x, 0)).a;
		float alphaRight = tex2D(TexBase, i.uv + float2(pixelSize.x, 0)).a;

		// Only boost if multiple neighbors have content (prevents edge bleeding)
		float neighborCount = (alphaUp > 0.1 ? 1.0 : 0.0) +
		                      (alphaDown > 0.1 ? 1.0 : 0.0) +
		                      (alphaLeft > 0.1 ? 1.0 : 0.0) +
		                      (alphaRight > 0.1 ? 1.0 : 0.0);

		// Only fill if at least 2 neighbors have content (we're inside, not on edge)
		if (neighborCount >= 2.0)
		{
			alpha = max(alpha, max(max(alphaUp, alphaDown), max(alphaLeft, alphaRight)));
		}
	}

	// Discard only fully transparent pixels
	if (alpha < 0.01)
	{
		discard;
	}

	// The target color from parameters
	float3 targetColor = float3(COLOR_R, COLOR_G, COLOR_B);

	// Calculate the overall brightness/luminance of the color (using proper weights)
	float brightness = dot(targetColor, float3(0.299, 0.587, 0.114));

	// Calculate color saturation (how "pure" the color is)
	float maxChannel = max(max(targetColor.r, targetColor.g), targetColor.b);
	float minChannel = min(min(targetColor.r, targetColor.g), targetColor.b);
	float saturation = (maxChannel > 0.0) ? (maxChannel - minChannel) / maxChannel : 0.0;

	// For saturated bright colors (like pure red), we need to go VERY dark
	// For desaturated colors, we can use moderate range
	// For dark colors, we need to go brighter

	// Saturated colors need stronger darkening
	float saturationFactor = saturation * 0.5; // 0 to 0.5

	// Calculate dynamic brightness range
	float minBrightness = lerp(0.15, 0.7, brightness) - saturationFactor; // Saturated bright colors get very dark mins
	float maxBrightness = lerp(1.8, 1.2, brightness); // Dark colors get brighter maxs

	// Clamp to reasonable values
	minBrightness = max(0.1, minBrightness);
	maxBrightness = min(2.0, maxBrightness);

	// Add animated flowing noise for ethereal effect
	// Bright colors need larger noise patches to be visible (lower scale = bigger patches)
	float noiseScale = lerp(8.0, 1.0, brightness); // Dark colors get fine detail, bright colors get larger patches
	float2 noiseUV = i.uv * noiseScale;
	float2 flowDir = float2(1.0, 0.0); // Flow horizontally (along circle direction)
	float noiseTime = TIME * 1.5; // Faster animation

	// Animate the noise by moving the sample position
	float2 animatedUV = noiseUV + flowDir * noiseTime;

	// Get noise value (0 to 1)
	float noiseValue = fbm(animatedUV);

	// Make dark spots smaller by using power function
	// This makes the noise more concentrated towards bright values
	noiseValue = pow(saturate(noiseValue), 0.6);

	// Remap noise with dynamic range based on color extremeness
	float brightnessMod = lerp(minBrightness, maxBrightness, noiseValue);

	// Apply noise to color
	float3 finalColor = targetColor * brightnessMod * i.color.rgb;

	// Use the enhanced alpha for smooth edges, combined with vertex alpha
	float finalAlpha = saturate(alpha * 1.5) * i.color.a;

	// Return fullbright color (no lighting applied)
	return float4(finalColor, finalAlpha);
}
