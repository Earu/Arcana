// Environmental Pollution Post-Processing Shader
// Creates realistic pollution effects that integrate with the world
// Features: world darkening, desaturation, atmospheric particles, subtle corruption

sampler BASETEXTURE : register(s0); // Framebuffer (world rendering)
sampler TEXTURE1 : register(s1);	// Noise texture for pollution patterns

// Shader constants
float4 C0 : register(c0); // C0.x = time, C0.y = pollution_intensity, C0.z = corruption_radius, C0.w = particle_density
float4 C1 : register(c1); // C1.x = center_x, C1.y = center_y, C1.z = darkening_strength, C1.w = desaturation_amount

struct PS_INPUT
{
	float2 uv : TEXCOORD0;
};

// Simple noise function
float noise(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// Smooth noise
float smoothNoise(float2 p)
{
	float2 i = floor(p);
	float2 f = frac(p);
	f = f * f * (3.0 - 2.0 * f);

	float a = noise(i);
	float b = noise(i + float2(1.0, 0.0));
	float c = noise(i + float2(0.0, 1.0));
	float d = noise(i + float2(1.0, 1.0));

	return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// Convert RGB to luminance for desaturation
float getLuminance(float3 color)
{
	return dot(color, float3(0.299, 0.587, 0.114));
}

float4 main(PS_INPUT frag) : COLOR
{
	float time = C0.x;
	float pollution_intensity = C0.y;
	float corruption_radius = C0.z;
	float particle_density = C0.w;

	float center_x = C1.x;
	float center_y = C1.y;
	float darkening_strength = C1.z;
	float desaturation_amount = C1.w;

	// Sample the original world color
	float3 world_color = tex2D(BASETEXTURE, frag.uv).xyz;

	// Smooth blending between screen-space and world-space modes
	// particle_density (C0.w) now contains the blend factor (0-1) instead of a hard flag
	float blend_factor = particle_density;

	// Always calculate both modes
	// SCREEN-SPACE: Circle-based falloff
	float2 pollution_center = float2(center_x, center_y);
	float2 to_center = frag.uv - pollution_center;
	float distance_to_center = length(to_center);
	float screen_falloff = 1.0 - smoothstep(0.0, corruption_radius, distance_to_center);

	// WORLD-SPACE: Uniform falloff across screen
	float world_falloff = corruption_radius;

	// Blend between the two based on distance to entity
	float pollution_falloff = lerp(screen_falloff, world_falloff, blend_factor);
	pollution_falloff = pow(abs(pollution_falloff), 1.5); // More dramatic falloff

	// Generate subtle noise for pollution variation
	float2 noise_uv = frag.uv * 8.0 + time * 0.1;
	float pollution_noise = smoothNoise(noise_uv) * 0.3 + 0.7;

	// Apply pollution effects only where there's falloff
	float final_pollution_strength = pollution_falloff * pollution_intensity * pollution_noise;

	// Darken the world in polluted areas
	float3 darkened_color = world_color * (1.0 - darkening_strength * final_pollution_strength);

	// Desaturate colors to make them look sickly
	float luminance = getLuminance(darkened_color);
	float3 desaturated_color = lerp(darkened_color, float3(luminance, luminance, luminance),
									desaturation_amount * final_pollution_strength);

		// Add magical corruption tint - dark purples and mystical colors
	float3 corruption_tint = float3(0.6, 0.4, 0.9); // Purple mystical tint
	float3 shadow_tint = float3(0.3, 0.2, 0.5);     // Dark purple shadows

	// Create magical energy patterns
	float2 magic_uv = frag.uv * 6.0 + time * 0.3;
	float magic_pattern = smoothNoise(magic_uv);
	magic_pattern = pow(magic_pattern, 2.0); // Sharper magical energy

	// Mix corruption colors based on magical patterns
	float3 magical_mix = lerp(shadow_tint, corruption_tint, magic_pattern);
	float3 tinted_color = lerp(desaturated_color, desaturated_color * magical_mix,
							   final_pollution_strength * 0.5);

	// Add magical energy distortion throughout the corruption
	float2 magical_distortion_uv = frag.uv;

	// Create swirling magical energy distortion
	float2 swirl_center = float2(0.5, 0.5);
	float2 to_swirl_center = frag.uv - swirl_center;
	float swirl_distance = length(to_swirl_center);

	// Magical swirling distortion
	float swirl_angle = time * 0.8 + swirl_distance * 8.0;
	float swirl_strength = final_pollution_strength * 0.006;

	magical_distortion_uv.x += sin(swirl_angle) * swirl_strength;
	magical_distortion_uv.y += cos(swirl_angle) * swirl_strength;

	// Add ripple distortion for mystical energy waves
	float ripple_pattern = sin(swirl_distance * 20.0 - time * 4.0) * 0.002;
	magical_distortion_uv += ripple_pattern * final_pollution_strength;

	// Re-sample with magical distortion
	if (final_pollution_strength > 0.1) {
		tinted_color = tex2D(BASETEXTURE, magical_distortion_uv).xyz;

		// Re-apply corruption effects to distorted sample
		tinted_color *= (1.0 - darkening_strength * final_pollution_strength);
		float magical_luminance = getLuminance(tinted_color);
		tinted_color = lerp(tinted_color, float3(magical_luminance, magical_luminance, magical_luminance),
							desaturation_amount * final_pollution_strength);
		tinted_color = lerp(tinted_color, tinted_color * magical_mix, final_pollution_strength * 0.5);
	}

	// Add magical energy highlights - glowing veins of corruption
	float2 vein_uv1 = frag.uv * 8.0 + time * 0.4;
	float2 vein_uv2 = frag.uv * 12.0 - time * 0.3;

	float magical_veins = smoothNoise(vein_uv1) * smoothNoise(vein_uv2);
	magical_veins = pow(magical_veins, 3.0); // Sharp, vein-like patterns

	// Add glowing purple/pink energy veins
	float3 energy_color = float3(0.8, 0.3, 1.0); // Bright magical purple
	float vein_intensity = smoothstep(0.7, 1.0, magical_veins) * final_pollution_strength;
	tinted_color += energy_color * vein_intensity * 0.3;

	// Blend between original and polluted based on overall intensity
	float3 final_color = lerp(world_color, tinted_color, pollution_intensity);

	return float4(final_color, 1.0);
}
