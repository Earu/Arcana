-- Arcana Magic Circle Bloom — custom screenspace bloom + glow pipeline.
-- Circles are drawn straight to the screen, where the engine's real z-buffer
-- occludes them exactly (world, props, viewmodel — no depth-texture tricks).
-- Their visible contribution is isolated by diffing framebuffer snapshots
-- (after - before) into a render target, which then feeds multiple separable
-- Gaussian blur passes (half-res tight bloom, quarter-res wide glow) that are
-- composited back with a screen blend.  No HDR required.
--
-- NOTE: the engine's SSAO depth pass (_rt_ResolvedFullFrameDepth) was tried
-- and abandoned for this: it randomly contains scene colors for entities
-- depending on view angle (engine-side, reproduces on Windows), making it
-- unusable as an occlusion source.
require("shader_to_gma")

if SERVER then
	resource.AddShader("arcana_bloom_ps30")
	resource.AddShader("arcana_passthrough_vs30")

	return
end

local BLOOM_ENABLED = CreateConVar("arcana_bloom", "1", FCVAR_ARCHIVE, "Enable Arcana bloom system")

local Arcana = Arcana

-- ProcessBloom owns drawing the circles to the screen, so the stub must still
-- run the draw callback or circles vanish before shaders are mounted.
Arcana.Bloom = Arcana.Bloom or {
	ProcessBloom = function(drawFunc) drawFunc() end,
	RenderBloom = function() end,
}

local function initBloom()
	local scrW, scrH = ScrW(), ScrH()

	-- Full-res: holds the circles' visible screen contribution each frame.
	local CIRCLE_RT = GetRenderTarget("arcana_circles_rt", scrW, scrH)

	-- Half-res ping-pong: tight bloom.
	local BLOOM_RT_A = GetRenderTarget("arcana_bloom_rt_a", scrW / 2, scrH / 2)
	local BLOOM_RT_B = GetRenderTarget("arcana_bloom_rt_b", scrW / 2, scrH / 2)

	-- Quarter-res ping-pong: wide glow fog.
	local GLOW_RT_A = GetRenderTarget("arcana_glow_rt_a", scrW / 4, scrH / 4)
	local GLOW_RT_B = GetRenderTarget("arcana_glow_rt_b", scrW / 4, scrH / 4)

	-- Full-res: framebuffer snapshots taken before/after the circles are drawn.
	local SNAPSHOT_PRE = GetRenderTarget("arcana_bloom_snap_pre", scrW, scrH)
	local SNAPSHOT_POST = GetRenderTarget("arcana_bloom_snap_post", scrW, scrH)

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
		["$texture1"] = SNAPSHOT_PRE:GetName(),
		["$alpha_blend"] = 0,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1, -- must match basetexture so the diff cancels exactly
		["$linearwrite"] = 1,
		["$c0_x"] = 1.0,
		["$c0_y"] = 0.0,
		["$c0_z"] = 4.0,
		["$c1_x"] = 1.0,
		["$c1_y"] = 0.0,
		-- Constants must be declared here or runtime SetFloat calls are ignored
		["$c2_x"] = 0.0, -- snapshot-diff mode, enabled only for the diff pass
		["$c2_y"] = 0.0, -- daylight boost (set per diff pass)
		["$c2_z"] = 1.0, -- dark-hue boost cap (set per diff pass)
	})

	-- Out of the world the engine never repaints the framebuffer, so the
	-- screen-blend composite accumulates to saturation on the stale pixels.
	local function eyeOutOfWorld()
		return bit.band(util.PointContents(EyePos()), CONTENTS_SOLID) ~= 0
	end

	-- Full pipeline: blur passes then additive composite with chromatic aberration.
	-- caScale scales the red/blue split of both composite passes: 1 (default) keeps
	-- the tuned amount, 0 composites clean for callers that do not want the fringe.
	function renderBloom(caScale)
		if not BLOOM_ENABLED:GetBool() then return end
		if eyeOutOfWorld() then return end

		caScale = caScale or 1

		-- ── Tight bloom — 3 successive H+V passes at half-res ────────────────
		blurPass(CIRCLE_RT, BLOOM_RT_A, 1, 0, 1, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 1, 1)
		blurPass(BLOOM_RT_B, BLOOM_RT_A, 1, 0, 1, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 1, 1)
		blurPass(BLOOM_RT_B, BLOOM_RT_A, 1, 0, 2, 1)
		blurPass(BLOOM_RT_A, BLOOM_RT_B, 0, 1, 2, 0.9) -- bake bloom intensity
		-- ── Glow fog — 2 successive H+V passes at quarter-res ────────────────
		-- Radii/intensity retuned after the composite gamma re-encode: the
		-- re-encode lifts faint tails ~4-6x, so the wide fog needs far less
		-- energy than it did when those tails were being gamma-crushed.
		blurPass(BLOOM_RT_B, GLOW_RT_A, 1, 0, 1, 1)
		blurPass(GLOW_RT_A, GLOW_RT_B, 0, 1, 1, 1)
		blurPass(GLOW_RT_B, GLOW_RT_A, 1, 0, 1, 1)
		blurPass(GLOW_RT_A, GLOW_RT_B, 0, 1, 1, 0.12) -- bake glow intensity
		-- ── Screen-blend composite ───────────────────────────────────────────
		-- Screen: dst' = src*(1-dst) + dst.  Behaves like additive in dark areas
		-- but shrinks the contribution where the framebuffer is already bright,
		-- preventing the circles' own colors from being washed out / over-exposed.
		render.OverrideBlend(true, BLEND_ONE_MINUS_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
		additiveComposite(BLOOM_RT_B, 0.025 * caScale) -- tight bloom with CA
		additiveComposite(GLOW_RT_B, 0.012 * caScale) -- wide glow fog with subtle CA
		render.OverrideBlend(false)
	end

	-- Capture by screen diff: snapshot the framebuffer, draw the circles to the
	-- screen (the real z-buffer occludes them exactly), snapshot again, then
	-- subtract.  CIRCLE_RT ends up holding only the circles' visible
	-- contribution, already masked by world/prop/viewmodel occlusion.
	local function processBloom(drawFunc)
		if not BLOOM_ENABLED:GetBool() or eyeOutOfWorld() then
			-- Bloom off: still responsible for putting the circles on screen
			drawFunc()

			return
		end

		-- A: screen before the circles
		render.CopyRenderTargetToTexture(SNAPSHOT_PRE)

		-- Circles drawn to the screen, z-tested against the real scene depth
		drawFunc()

		-- B: screen after
		render.CopyRenderTargetToTexture(SNAPSHOT_POST)

		-- CIRCLE_RT = max(B - A, 0) → the circles' contribution only.  Done in
		-- the bloom shader (diff mode) rather than a subtractive blend op:
		-- both snapshots are sampled by the same draw, so HDR tonemap scaling
		-- affects them identically and cancels instead of causing full-screen
		-- bloom while the eye-adaptation is catching up.
		render.PushRenderTarget(CIRCLE_RT)
		render.Clear(0, 0, 0, 0)
		blurMat:SetTexture("$basetexture", SNAPSHOT_POST)
		blurMat:SetTexture("$texture1", SNAPSHOT_PRE)
		blurMat:SetFloat("$c2_x", 1.0)
		-- Bright backgrounds swallow the circles' contribution twice (alpha blending at
		-- capture, screen blend at composite), so daylight bloom reads weak.  This
		-- scales the captured contribution with background luminance: 0 = off,
		-- ~2 = roughly restores dark-scene punch on a full-daylight background.
		blurMat:SetFloat("$c2_y", 2)
		-- Max perceptual boost for dark hues (purple, deep green): their
		-- contribution carries little luminance and would barely bloom, so the
		-- shader normalises it by luma, capped at this factor.  1 = off.
		blurMat:SetFloat("$c2_z", 5)
		render.SetMaterial(blurMat)
		render.DrawScreenQuad()
		blurMat:SetFloat("$c2_x", 0.0)
		render.PopRenderTarget()
	end

	Arcana.Bloom = {
		ProcessBloom = processBloom,
		RenderBloom = renderBloom,
	}
end

WaitForShaderMounted({"arcana_bloom_ps30", "arcana_passthrough_vs30"}, function(available)
	if not available then return end

	initBloom()
end)
