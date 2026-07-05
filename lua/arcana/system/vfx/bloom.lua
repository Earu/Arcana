-- Arcana Magic Circle Bloom — custom screenspace bloom + glow pipeline.
-- Captures circles to a render target each frame, applies multiple separable
-- Gaussian blur passes (half-res for tight bloom, quarter-res for wide glow),
-- then composites both layers additively inside a cam.Start2D() pass so the
-- viewmodel renders after and naturally occludes the bloom.  No HDR required.
require("shader_to_gma")

if SERVER then
	resource.AddShader("arcana_bloom_ps30")
	resource.AddShader("arcana_passthrough_vs30")

	return
end

local BLOOM_ENABLED = CreateConVar("arcana_bloom", "1", FCVAR_ARCHIVE, "Enable Arcana bloom system")

local Arcana = Arcana

-- ── World-depth occlusion for the bloom capture ───────────────────────────────
-- The capture RT's depth buffer is NOT the scene's depth buffer (RT depth is a
-- separate buffer shared among render targets), so circles rendered into the RT
-- cannot be z-tested against the world.  Instead the engine's SSAO depth pass is
-- enabled while bloom is in use, and arcana_circle_ps30 clips occluded pixels
-- against _rt_ResolvedFullFrameDepth ($texture1, $c2_x toggle).
local lastBloomFrame = -100 -- last frame ProcessBloom ran (drives NeedsDepthPass)
local depthPassFrame = -100 -- last frame the engine was told to render the depth pass
local captureActive = false -- true while inside a ProcessBloom capture

-- Pre-create the resolved depth RT as 32-bit float BEFORE the engine lazily
-- creates it 8-bit on the first depth pass: 8 bits over the 4000-unit range is
-- ~15.7 units per step, which wrongly occludes circle pixels near geometry
-- (e.g. the lower half of a circle lying on the ground).  Must run at file
-- load, ahead of any NeedsDepthPass-triggered pass; if the RT somehow already
-- exists this returns it unchanged.
if system.IsWindows() and render.GetResolvedFullFrameDepth then
	GetRenderTargetEx(
		"_rt_resolvedfullframedepth",
		1, 1, -- ignored with RT_SIZE_FULL_FRAME_BUFFER
		RT_SIZE_FULL_FRAME_BUFFER,
		MATERIAL_RT_DEPTH_SHARED,
		bit.bor(4, 8, 256, 512), -- CLAMPS | CLAMPT | NOMIP | NOLOD
		0,
		27 -- IMAGE_FORMAT_R32F
	)
end

hook.Add("NeedsDepthPass", "arcana_bloom_depth", function()
	if not BLOOM_ENABLED:GetBool() then return end
	if FrameNumber() - lastBloomFrame > 3 then return end

	depthPassFrame = FrameNumber()

	return true
end)

-- Returns the resolved depth texture while a bloom capture is running and the
-- depth pass is fresh; nil otherwise (normal draws keep using the real z-test).
local function getDepthClipTexture()
	if not captureActive then return nil end
	if not render.GetResolvedFullFrameDepth then return nil end
	if FrameNumber() - depthPassFrame > 1 then return nil end

	return render.GetResolvedFullFrameDepth()
end

Arcana.Bloom = Arcana.Bloom or {
	ProcessBloom = function() end,
	RenderBloom = function() end,
	GetDepthClipTexture = getDepthClipTexture,
}

local function initBloom()
	local scrW, scrH = ScrW(), ScrH()

	-- Full-res: captures the raw circles each frame.
	local CIRCLE_RT = GetRenderTarget("arcana_circles_rt", scrW, scrH)

	-- Half-res ping-pong: tight bloom.
	local BLOOM_RT_A = GetRenderTarget("arcana_bloom_rt_a", scrW / 2, scrH / 2)
	local BLOOM_RT_B = GetRenderTarget("arcana_bloom_rt_b", scrW / 2, scrH / 2)

	-- Quarter-res ping-pong: wide glow fog.
	local GLOW_RT_A = GetRenderTarget("arcana_glow_rt_a", scrW / 4, scrH / 4)
	local GLOW_RT_B = GetRenderTarget("arcana_glow_rt_b", scrW / 4, scrH / 4)

	-- Single material reused for blur passes and the composite passthrough.
	local blurMat

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
		blurMat:SetFloat("$c1_x", 1.0) -- intensity already baked into the RT
		blurMat:SetFloat("$c1_y", caStrength or 0.0)
		render.SetMaterial(blurMat)
		render.DrawScreenQuad()
	end

	blurMat = CreateShaderMaterial("arcana_bloom_blur", {
		["$pixshader"] = "arcana_bloom_ps30",
		["$vertexshader"] = "arcana_passthrough_vs30",
		["$basetexture"] = CIRCLE_RT:GetName(),
		["$alpha_blend"] = 0,
		["$linearread_basetexture"] = 1,
		["$linearwrite"] = 1,
		["$c0_x"] = 1.0,
		["$c0_y"] = 0.0,
		["$c0_z"] = 4.0,
		["$c1_x"] = 1.0,
		["$c1_y"] = 0.0,
	})

	-- Full pipeline: blur passes then additive composite with chromatic aberration.
	-- Called by magic_circle.lua inside cam.Start2D() so the composite is written
	-- before the viewmodel renders, which then draws on top and occludes the bloom.
	function renderBloom()
		if not BLOOM_ENABLED:GetBool() then return end

		-- ── Tight bloom — 3 successive H+V passes at half-res ────────────────
		blurPass(CIRCLE_RT, BLOOM_RT_A, 1, 0, 1, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 1, 1)
		blurPass(BLOOM_RT_B, BLOOM_RT_A, 1, 0, 2, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 2, 1)
		blurPass(BLOOM_RT_B, BLOOM_RT_A, 1, 0, 3, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 3, 0.9) -- bake bloom intensity
		-- ── Glow fog — 2 successive H+V passes at quarter-res ────────────────
		blurPass(BLOOM_RT_B, GLOW_RT_A, 1, 0, 2, 1)
		blurPass(GLOW_RT_A, GLOW_RT_B, 0, 1, 2, 1)
		blurPass(GLOW_RT_B, GLOW_RT_A, 1, 0, 3, 1)
		blurPass(GLOW_RT_A, GLOW_RT_B, 0, 1, 3, 0.3) -- bake glow intensity
		-- ── Screen-blend composite ───────────────────────────────────────────
		-- Screen: dst' = src*(1-dst) + dst.  Behaves like additive in dark areas
		-- but shrinks the contribution where the framebuffer is already bright,
		-- preventing the circles' own colors from being washed out / over-exposed.
		render.OverrideBlend(true, BLEND_ONE_MINUS_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		additiveComposite(BLOOM_RT_B, 0.025) -- tight bloom with CA
		additiveComposite(GLOW_RT_B, 0.012) -- wide glow fog with subtle CA
		render.OverrideBlend(false)
	end

	local function processBloom(drawFunc)
		if not BLOOM_ENABLED:GetBool() then return end

		lastBloomFrame = FrameNumber()
		render.PushRenderTarget(CIRCLE_RT)
		-- Clear depth too: the RT depth buffer holds garbage from other RT work,
		-- world occlusion is handled in-shader via GetDepthClipTexture instead.
		render.Clear(0, 0, 0, 0, true, true)
		captureActive = true
		drawFunc()
		captureActive = false
		render.PopRenderTarget()
	end

	Arcana.Bloom = {
		ProcessBloom = processBloom,
		RenderBloom = renderBloom,
		GetDepthClipTexture = getDepthClipTexture,
	}
end

WaitForShaderMounted({"arcana_bloom_ps30", "arcana_passthrough_vs30"}, function(available)
	if not available then return end

	initBloom()
end)