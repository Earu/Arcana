#include "common.hlsl"

// Raw tinted blit.  Unlike UnlitGeneric screen draws, this applies no tonemap
// scaling or gamma conversion, so a screen snapshot drawn back through it
// (tint 1,1,1,1) restores the framebuffer exactly.  The tint ($c0) lets the
// corruption mask pipeline rasterise into individual colour channels.

struct PS_IN { float2 uv : TEXCOORD0; };

float4 main(PS_IN i) : COLOR
{
	return tex2D(TexBase, i.uv) * Constants0;
}
