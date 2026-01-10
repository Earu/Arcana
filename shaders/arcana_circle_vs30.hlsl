#include "common_vs.hlsl"

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o;

	// Transform position to screen space
	o.projPos = mul(i.pos, cModelViewProj);

	// Pass through texture coordinates
	o.uv = i.uv;

	// Pass through vertex color
	o.color = i.color;

	return o;
}
