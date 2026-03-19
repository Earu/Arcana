-- Arcana Magic Circle Bloom — custom screenspace bloom + glow pipeline.
-- Captures circles to a render target each frame, applies multiple separable
-- Gaussian blur passes (half-res for tight bloom, quarter-res for wide glow),
-- then composites both layers additively inside a cam.Start2D() pass so the
-- viewmodel renders after and naturally occludes the bloom.  No HDR required.
--
-- Loaded CLIENT-side only (circles.lua guards the include).
-- Windows only — mirrors the system.IsWindows() guard in ring.lua.

if not system.IsWindows() then return end

Arcana        = Arcana or {}
Arcana.Circle = Arcana.Circle or {}

-- Exposed so magic_circle.lua's draw hook can reference it without a hard dependency.
-- Remains nil until the bloom shader has been mounted successfully.
Arcana.Circle.Bloom = nil

-- ── Render targets ────────────────────────────────────────────────────────────
local scrW, scrH = ScrW(), ScrH()

-- Full-res: captures the raw circles each frame.
local CIRCLE_RT  = GetRenderTarget("arcana_circles_rt", scrW,     scrH)

-- Half-res ping-pong: tight bloom.
local BLOOM_RT_A = GetRenderTarget("arcana_bloom_rt_a", scrW / 2, scrH / 2)
local BLOOM_RT_B = GetRenderTarget("arcana_bloom_rt_b", scrW / 2, scrH / 2)

-- Quarter-res ping-pong: wide glow fog.
local GLOW_RT_A  = GetRenderTarget("arcana_glow_rt_a",  scrW / 4, scrH / 4)
local GLOW_RT_B  = GetRenderTarget("arcana_glow_rt_b",  scrW / 4, scrH / 4)

-- ── Material ──────────────────────────────────────────────────────────────────
-- Single material reused for blur passes and the composite passthrough.
local blurMat

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- These are defined before initBloom so doBloom (a closure) can capture them.

-- Run one H or V blur pass: reads srcRT, writes blurred output to dstRT.
-- intensity is baked into col.rgb so the composite can use ONE/ONE blending.
local function blurPass(srcRT, dstRT, dirX, dirY, radius, intensity)
	render.PushRenderTarget(dstRT)
	render.Clear(0, 0, 0, 0)
	blurMat:SetTexture("$basetexture", srcRT)
	blurMat:SetFloat("$c0_x", dirX)
	blurMat:SetFloat("$c0_y", dirY)
	blurMat:SetFloat("$c0_z", radius)
	blurMat:SetFloat("$c1_x", intensity)
	blurMat:SetFloat("$c1_y", 0.0) -- CA must be off during blur passes
	render.SetMaterial(blurMat)
	render.DrawScreenQuad()
	render.PopRenderTarget()
end

-- Draw srcRT additively with optional chromatic aberration.
-- Uses the blur shader in passthrough mode: dir=(0,0) → step=0 → all 9 taps
-- hit the same UV → output = 1.0 × centre pixel.
-- caStrength controls the red/blue radial split: 0 = none, ~0.02 = visible.
local function additiveComposite(srcRT, caStrength)
	blurMat:SetTexture("$basetexture", srcRT)
	blurMat:SetFloat("$c0_x", 0.0)
	blurMat:SetFloat("$c0_y", 0.0)
	blurMat:SetFloat("$c0_z", 0.0)
	blurMat:SetFloat("$c1_x", 1.0)           -- intensity already baked into the RT
	blurMat:SetFloat("$c1_y", caStrength or 0.0)
	render.SetMaterial(blurMat)
	render.DrawScreenQuad()
end

-- ── Init ──────────────────────────────────────────────────────────────────────
local function initBloom()
	blurMat = CreateShaderMaterial("arcana_bloom_blur", {
		["$pixshader"]              = "arcana_bloom_ps30",
		["$vertexshader"]           = "arcana_passthrough_vs30",
		["$basetexture"]            = CIRCLE_RT:GetName(),
		["$alpha_blend"]            = 0,
		["$linearread_basetexture"] = 1,
		["$linearwrite"]            = 1,
		["$c0_x"] = 1.0,
		["$c0_y"] = 0.0,
		["$c0_z"] = 4.0,
		["$c1_x"] = 1.0,
		["$c1_y"] = 0.0,
	})

	-- Full pipeline: blur passes then additive composite with chromatic aberration.
	-- Called by magic_circle.lua inside cam.Start2D() so the composite is written
	-- before the viewmodel renders, which then draws on top and occludes the bloom.
	local function doBloom()
		--render.OverrideDepthEnable(true, true)
		-- ── Tight bloom — 3 successive H+V passes at half-res ────────────────
		blurPass(CIRCLE_RT,  BLOOM_RT_A, 1, 0, 1, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 1, 1)

		blurPass(BLOOM_RT_B, BLOOM_RT_A, 1, 0, 2, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 2, 1)

		blurPass(BLOOM_RT_B, BLOOM_RT_A, 1, 0, 3, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 3, 0.9) -- bake bloom intensity

		-- ── Glow fog — 2 successive H+V passes at quarter-res ────────────────
		blurPass(BLOOM_RT_B, GLOW_RT_A, 1, 0, 2, 1)
		blurPass(GLOW_RT_A,  GLOW_RT_B, 0, 1, 2, 1)

		blurPass(GLOW_RT_B,  GLOW_RT_A, 1, 0, 3, 1)
		blurPass(GLOW_RT_A,  GLOW_RT_B, 0, 1, 3, 0.3) -- bake glow intensity

		-- ── Screen-blend composite ───────────────────────────────────────────
		-- Screen: dst' = src*(1-dst) + dst.  Behaves like additive in dark areas
		-- but shrinks the contribution where the framebuffer is already bright,
		-- preventing the circles' own colors from being washed out / over-exposed.
		render.OverrideBlend(true,
			BLEND_ONE_MINUS_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD,
			BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)

		additiveComposite(BLOOM_RT_B, 0.025) -- tight bloom with CA
		additiveComposite(GLOW_RT_B,  0.012) -- wide glow fog with subtle CA

		render.OverrideBlend(false)
		--render.OverrideDepthEnable(false, false)
	end

	Arcana.Circle.Bloom = { CIRCLE_RT = CIRCLE_RT, DoBloom = doBloom }
end

-- ── Shader availability ───────────────────────────────────────────────────────
if file.Exists("shaders/fxc/arcana_bloom_ps30.vcs", "GAME") then
	initBloom()
else
	hook.Add("ShaderMounted", "ArcanaBloom_Init", function()
		initBloom()
		hook.Remove("ShaderMounted", "ArcanaBloom_Init")
	end)
end
