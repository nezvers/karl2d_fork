// RENDER3D: forward toon shader of the 3D layer (D3D11). Fixed resource contract: b0 globals, b1 material, t0 instance data (vertex stage), t1 albedo, t2 ramp.
cbuffer Globals : register(b0) {
	float4x4 view_proj;
	float4x4 view;
	float4 camera_position;
	float4 time;
	float4 viewport;
	float4 sun_direction;
	float4 sun_color;
	float4 ambient_sky;
	float4 ambient_ground;
	float4 fog_color;
	float4 fog_params;
	float4 wind;
	float4 wind_params;
	float4 user[4];
};

cbuffer Material : register(b1) {
	float4 tint;
	float4 toon;
	float4 rim_color;
	float4 rim_params;
	float4 specular;
	float4 outline_color;
	float4 outline_params;
	float4 flags;
};

Texture2D instance_data : register(t0);
Texture2D albedo_tex : register(t1);
Texture2D ramp_tex : register(t2);
SamplerState point_smp : register(s0);
SamplerState linear_smp : register(s1);

#define INSTANCES_PER_ROW 128
#define INSTANCE_TEXELS 8

struct VS_IN {
	float3 position : POSITION;
	float3 normal : NORMAL;
	float2 uv : TEXCOORD0;
	float4 color : COLOR0;
	uint4 joints : BLENDINDICES;
	float4 weights : BLENDWEIGHT;
	float4 outline_normal : TEXCOORD1;
	uint instance : SV_InstanceID;
};

struct VS_OUT {
	float4 clip : SV_Position;
	float3 world_pos : TEXCOORD0;
	float3 normal : TEXCOORD1;
	float2 uv : TEXCOORD2;
	float4 color : COLOR0;
	float4 instance_tint : COLOR1;
};

float4 fetch_instance(uint instance, uint k) {
	uint x = (instance % INSTANCES_PER_ROW) * INSTANCE_TEXELS + k;
	uint y = instance / INSTANCES_PER_ROW;
	return instance_data.Load(int3(x, y, 0));
}

float3 transform_point(float4 r0, float4 r1, float4 r2, float3 p) {
	return float3(dot(r0.xyz, p) + r0.w, dot(r1.xyz, p) + r1.w, dot(r2.xyz, p) + r2.w);
}

float3 transform_direction(float4 r0, float4 r1, float4 r2, float3 d) {
	return float3(dot(r0.xyz, d), dot(r1.xyz, d), dot(r2.xyz, d));
}

VS_OUT vs_main(VS_IN v) {
	float4 r0 = fetch_instance(v.instance, 0);
	float4 r1 = fetch_instance(v.instance, 1);
	float4 r2 = fetch_instance(v.instance, 2);

	VS_OUT o;
	float3 world = transform_point(r0, r1, r2, v.position);
	o.world_pos = world;
	o.normal = normalize(transform_direction(r0, r1, r2, v.normal));
	o.uv = v.uv;
	o.color = v.color;
	o.instance_tint = fetch_instance(v.instance, 3);
	o.clip = mul(view_proj, float4(world, 1));
	return o;
}

VS_OUT vs_outline(VS_IN v) {
	float4 r0 = fetch_instance(v.instance, 0);
	float4 r1 = fetch_instance(v.instance, 1);
	float4 r2 = fetch_instance(v.instance, 2);

	float3 base_normal = v.outline_normal.xyz;
	if (dot(base_normal, base_normal) < 0.001) {
		base_normal = v.normal;
	}

	float3 world = transform_point(r0, r1, r2, v.position);
	float3 world_normal = normalize(transform_direction(r0, r1, r2, base_normal));

	float4 clip = mul(view_proj, float4(world, 1));
	float4 clip_pushed = mul(view_proj, float4(world + world_normal, 1));
	float2 direction = clip_pushed.xy / clip_pushed.w - clip.xy / clip.w;
	direction = normalize(direction + float2(1e-6, 0));
	clip.xy += direction * outline_params.x * 2.0 * viewport.zw * clip.w;

	VS_OUT o;
	o.clip = clip;
	o.world_pos = world;
	o.normal = world_normal;
	o.uv = v.uv;
	o.color = v.color;
	o.instance_tint = fetch_instance(v.instance, 3);
	return o;
}

float toon_light(float t) {
	if (toon.z > 0.5) {
		return ramp_tex.Sample(linear_smp, float2(t, 0.5)).r;
	}

	float bands = max(toon.x, 1.0);
	float x = saturate(t) * bands;
	float soft = clamp(toon.y * bands, 0.001, 0.5);
	return saturate((floor(x) + smoothstep(1.0 - soft, 1.0, frac(x))) / bands);
}

float4 ps_main(VS_OUT i) : SV_Target {
	float4 base = tint * i.instance_tint;

	if (flags.x > 0.5) {
		base *= albedo_tex.Sample(linear_smp, i.uv);
	}

	if (flags.y > 0.5) {
		base *= i.color;
	}

	if (flags.z > 0.0 && base.a < flags.z) {
		discard;
	}

	if (flags.w > 0.5) {
		return float4(base.rgb, base.a);
	}

	float3 n = normalize(i.normal);
	float3 view_vec = camera_position.xyz - i.world_pos;
	float dist = length(view_vec);
	float3 v = view_vec / max(dist, 0.0001);
	float3 l = sun_direction.xyz;
	float ndl = dot(n, l);

	float lit = toon_light(ndl * 0.5 + 0.5);
	float shade = lerp(toon.w, 1.0, lit);
	float3 ambient = lerp(ambient_ground.rgb, ambient_sky.rgb, n.y * 0.5 + 0.5);
	float3 color = base.rgb * (ambient * (1.0 - 0.5 * lit) + sun_color.rgb * shade);

	if (specular.a > 0.0) {
		float3 h = normalize(l + v);
		float s = pow(saturate(dot(n, h)), specular.a);
		color += specular.rgb * smoothstep(0.5, 0.55, s) * lit;
	}

	float rim = pow(1.0 - saturate(dot(n, v)), max(rim_color.a, 0.001));
	rim = smoothstep(rim_params.x, rim_params.x + max(rim_params.y, 0.001), rim);
	color += rim_color.rgb * rim * saturate(ndl * 0.5 + 0.5);

	if (fog_params.x > 0.0) {
		float fog = 1.0 - exp2(-fog_params.x * max(dist - fog_params.y, 0.0));
		color = lerp(color, fog_color.rgb, saturate(fog));
	}

	return float4(color, base.a);
}

float4 ps_outline(VS_OUT i) : SV_Target {
	float3 color = outline_color.rgb;

	if (fog_params.x > 0.0) {
		float dist = length(camera_position.xyz - i.world_pos);
		float fog = 1.0 - exp2(-fog_params.x * max(dist - fog_params.y, 0.0));
		color = lerp(color, fog_color.rgb, saturate(fog));
	}

	return float4(color, outline_color.a);
}
