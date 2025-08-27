#include "common_vs.hlsl"

struct VS_OUT
{
	float4 projPos	: POSITION;
	float2 uv		: TEXCOORD0;
	float4 color	: TEXCOORD1;
	float3 normal	: TEXCOORD2;
};

VS_OUT main( const VS_INPUT v )
{
	VS_OUT o = ( VS_OUT )0;

	o.projPos = mul( float4( v.pos.xyz, 1.0f ), cModelViewProj );
	o.uv = v.uv;
	o.color = v.color;
	o.normal = normalize( v.normal.xyz );

	return o;
}