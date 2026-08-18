-- Shared full-screen framebuffer scratch target.
-- Exports: Arcana.GetScreenScratchRT()
--
-- Several effects need "the screen as it is right now" to sample from: the
-- corruption mask rasterisation snapshots and restores it, the mana crystal
-- feeds it through its dispersion passes, the condensator lens warps it.  All
-- three used to own a private full-screen RGBA8888 target, which is 33 MB EACH
-- at 4K, and Source never frees a render target.  They are the same buffer used
-- at different moments, so they share one.
--
-- Not the engine's _rt_FullFrameFB: other addons write into it mid-frame (the
-- halo library among them), so its contents are not ours to rely on.  This one
-- is Arcana's, and every call site is known.
--
-- CONTRACT: copy into it, read from it, and be done inside a single
-- uninterrupted stretch of drawing.  Never hold it across a nested entity draw,
-- a hook dispatch, or a frame boundary - the next caller will have overwritten
-- it.  Today's callers all satisfy this: entity draws are sequential and none
-- of them dispatches other draw work while holding the buffer.

if SERVER then return end

Arcana = Arcana or {}

local SCRATCH_RT_NAME = "arcana_fb_scratch"
local GetRenderTarget = _G.GetRenderTarget
local ScrW, ScrH = _G.ScrW, _G.ScrH

-- Allocated on first use rather than at load: a client that never sees any of
-- these effects should not pay the 8-33 MB for them.
function Arcana.GetScreenScratchRT()
	return GetRenderTarget(SCRATCH_RT_NAME, ScrW(), ScrH())
end
