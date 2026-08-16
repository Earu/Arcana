#include "common_vs.hlsl"

// The mana box is drawn as a local-space unit cube under a pushed model matrix,
// so the raw vertex position IS the box-local coordinate the pixel shader needs
// for its interior raycast (see arcana_manabox_ps30).

struct VS_OUT
{
	float4 projPos	: POSITION;
	float2 uv		: TEXCOORD0;
	float4 color	: TEXCOORD1;
	float3 normal	: TEXCOORD2;
	float3 lpos		: TEXCOORD3;
};

VS_OUT main( const VS_INPUT v )
{
	VS_OUT o = ( VS_OUT )0;

	o.projPos = mul( float4( v.pos.xyz, 1.0f ), cModelViewProj );
	o.uv = v.uv;
	o.color = v.color;
	o.normal = normalize( v.normal.xyz );
	o.lpos = v.pos.xyz;

	return o;
}
