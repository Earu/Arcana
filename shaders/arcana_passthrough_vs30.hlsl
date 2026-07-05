#include "common_vs.hlsl"

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o;

	// Transform position to screen space
	o.projPos = mul(i.pos, cModelViewProj);

	// Linear view-space depth for manual depth testing against
	// _rt_ResolvedFullFrameDepth (which stores projPos.w / 4000)
	o.projW = o.projPos.w;

	// Pass through texture coordinates
	o.uv = i.uv;

	// Pass through vertex color
	o.color = i.color;

	return o;
}
