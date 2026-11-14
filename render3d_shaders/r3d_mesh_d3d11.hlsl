// RENDER3D: forward toon shader of the 3D layer (D3D11). Fixed resource contract: b0 globals, b1 material, t0 instance data (vertex stage), t1 albedo, t2 ramp. Instance texels 0-2 transform rows, 3 tint, 4 tween (from, to, start, duration), 5 tween (easing, effect, loop, phase), 6-7 free.
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
	float4 lights;
	float4 cluster;
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
	float4 wind_material;
};

Texture2D instance_data : register(t0);
Texture2D albedo_tex : register(t1);
Texture2D ramp_tex : register(t2);
Texture2D light_data : register(t3);
Texture2D cluster_grid : register(t4);
Texture2D light_indices : register(t5);
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
	float2 tween : TEXCOORD3;
	float4 clip_info : TEXCOORD4;
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

float ease(float t, int id) {
	float x = saturate(t);
	if (id == 1) return x * x;
	if (id == 2) return 1.0 - (1.0 - x) * (1.0 - x);
	if (id == 3) return x < 0.5 ? 2.0 * x * x : 1.0 - 2.0 * (1.0 - x) * (1.0 - x);
	if (id == 4) {
		float d = x - 1.0;
		return 1.0 + 2.70158 * d * d * d + 1.70158 * d * d;
	}
	return x;
}

float tween_value(float4 p0, float4 p1) {
	if (p0.w <= 0.0) return 1.0;
	float u = (time.x - p0.z) / p0.w;
	int loop_mode = int(p1.z + 0.5);
	if (loop_mode == 0) {
		u = saturate(u);
	} else if (loop_mode == 1) {
		u = frac(max(u, 0.0));
	} else {
		float m = frac(max(u, 0.0) * 0.5) * 2.0;
		u = m < 1.0 ? m : 2.0 - m;
	}
	return lerp(p0.x, p0.y, ease(u, int(p1.x + 0.5)));
}

float3 wind_offset(float3 world, float local_y, float phase) {
	float bend = wind_material.x * pow(saturate(local_y / wind_material.y), 2.0);
	if (bend <= 0.0) return float3(0.0, 0.0, 0.0);
	float t = time.x * wind.w;
	float w = sin(t + dot(world.xz, wind.xz) * 0.6 + phase) + 0.5 * wind_params.x * sin(t * 2.3 + world.x * 0.9 + phase * 1.7);
	return wind.xyz * (w * bend);
}

VS_OUT vs_common(VS_IN v, bool outline) {
	float4 r0 = fetch_instance(v.instance, 0);
	float4 r1 = fetch_instance(v.instance, 1);
	float4 r2 = fetch_instance(v.instance, 2);
	float4 p0 = fetch_instance(v.instance, 4);
	float4 p1 = fetch_instance(v.instance, 5);

	int effect = int(p1.y + 0.5);
	float tw = tween_value(p0, p1);

	float3 local = v.position;
	if (effect == 1) local *= tw;
	float3 world = transform_point(r0, r1, r2, local);
	if (effect == 3) world.y += tw;
	world += wind_offset(world, v.position.y, p1.w);

	float3 normal = v.normal;
	if (outline) {
		normal = v.outline_normal.xyz;
		if (dot(normal, normal) < 0.001) normal = v.normal;
	}
	float3 world_normal = normalize(transform_direction(r0, r1, r2, normal));

	float4 clip = mul(view_proj, float4(world, 1));
	if (outline) {
		float4 clip_pushed = mul(view_proj, float4(world + world_normal, 1));
		float2 direction = clip_pushed.xy / clip_pushed.w - clip.xy / clip.w;
		direction = normalize(direction + float2(1e-6, 0));
		clip.xy += direction * outline_params.x * 2.0 * viewport.zw * clip.w;
	}

	VS_OUT o;
	o.clip = clip;
	o.world_pos = world;
	o.normal = world_normal;
	o.uv = v.uv;
	o.color = v.color;
	o.instance_tint = fetch_instance(v.instance, 3);
	o.tween = float2(tw, float(effect));
	o.clip_info = float4(clip.x, clip.y, clip.w, -mul(view, float4(world, 1)).z);
	return o;
}

VS_OUT vs_main(VS_IN v) {
	return vs_common(v, false);
}

VS_OUT vs_outline(VS_IN v) {
	return vs_common(v, true);
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

int2 data_texel(int n) {
	return int2(n % 1024, n / 1024);
}

float3 cluster_lights(float3 n, float3 world, float4 clip_info) {
	int light_count = int(lights.x);
	if (light_count == 0) return float3(0.0, 0.0, 0.0);

	float2 ndc = clip_info.xy / clip_info.z;
	int cx = clamp(int((ndc.x * 0.5 + 0.5) * lights.y), 0, int(lights.y) - 1);
	int cy = clamp(int((ndc.y * 0.5 + 0.5) * lights.z), 0, int(lights.z) - 1);
	int cz = clamp(int(log(max(clip_info.w, cluster.x)) * cluster.z + cluster.w), 0, int(lights.w) - 1);
	int cluster_index = (cz * int(lights.z) + cy) * int(lights.y) + cx;

	float4 cell = cluster_grid.Load(int3(data_texel(cluster_index), 0));
	int offset = int(cell.x + 0.5);
	int count = int(cell.y + 0.5);
	float3 total = float3(0.0, 0.0, 0.0);

	[loop] for (int k = 0; k < count; k++) {
		int entry = offset + k;
		float4 index_texel = light_indices.Load(int3(data_texel(entry / 4), 0));
		int light_index = int(index_texel[entry % 4] + 0.5);

		float4 l0 = light_data.Load(int3(data_texel(light_index * 3), 0));
		float4 l1 = light_data.Load(int3(data_texel(light_index * 3 + 1), 0));
		float4 l2 = light_data.Load(int3(data_texel(light_index * 3 + 2), 0));

		float3 to_light = l0.xyz - world;
		float dist = length(to_light);
		if (dist >= l0.w) continue;

		float3 dir = to_light / max(dist, 0.0001);
		float falloff = saturate(1.0 - (dist * dist) / (l0.w * l0.w));
		falloff *= falloff;

		float cone = 1.0;
		if (l1.w > -1.5) {
			cone = smoothstep(l1.w, max(l2.w, l1.w + 0.001), dot(-dir, l2.xyz));
		}

		float lit = toon_light(saturate(dot(n, dir)) * 0.5 + 0.5);
		total += l1.xyz * (lit * falloff * cone);
	}

	return total;
}

float4 ps_main(VS_OUT i) : SV_Target {
	float4 base = tint * i.instance_tint;
	int effect = int(i.tween.y + 0.5);

	if (flags.x > 0.5) {
		base *= albedo_tex.Sample(linear_smp, i.uv);
	}

	if (flags.y > 0.5) {
		base *= i.color;
	}

	if (effect == 2) {
		base.a *= i.tween.x;
	}

	if (flags.z > 0.0 && base.a < flags.z) {
		discard;
	}

	float3 color;

	if (flags.w > 0.5) {
		color = base.rgb;
	} else {
		float3 n = normalize(i.normal);
		float3 view_vec = camera_position.xyz - i.world_pos;
		float dist = length(view_vec);
		float3 v = view_vec / max(dist, 0.0001);
		float3 l = sun_direction.xyz;
		float ndl = dot(n, l);

		float lit = toon_light(ndl * 0.5 + 0.5);
		float shade = lerp(toon.w, 1.0, lit);
		float3 ambient = lerp(ambient_ground.rgb, ambient_sky.rgb, n.y * 0.5 + 0.5);
		color = base.rgb * (ambient * (1.0 - 0.5 * lit) + sun_color.rgb * shade + cluster_lights(n, i.world_pos, i.clip_info));

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
	}

	if (effect == 4) {
		color += i.tween.x;
	}

	return float4(color, base.a);
}

float4 ps_outline(VS_OUT i) : SV_Target {
	float3 color = outline_color.rgb;
	float alpha = outline_color.a;

	if (int(i.tween.y + 0.5) == 2) {
		alpha *= i.tween.x;
	}

	if (fog_params.x > 0.0) {
		float dist = length(camera_position.xyz - i.world_pos);
		float fog = 1.0 - exp2(-fog_params.x * max(dist - fog_params.y, 0.0));
		color = lerp(color, fog_color.rgb, saturate(fog));
	}

	return float4(color, alpha);
}
