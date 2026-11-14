// RENDER3D: forward toon shader of the 3D layer for GL (#version 330 core) and WebGL2 (#version 300 es). The backend prepends the version header and one of R3D_VERTEX / R3D_FRAGMENT, plus R3D_OUTLINE for the outline pass. Same resource contract as the HLSL file: block 0 globals, block 1 material, unit 0 instance data (vertex stage), unit 1 albedo, unit 2 ramp.

#ifdef R3D_VERTEX
#define VARYING out
#else
#define VARYING in
#endif

layout(std140) uniform Globals {
	mat4 view_proj;
	mat4 view;
	vec4 camera_position;
	vec4 time;
	vec4 viewport;
	vec4 sun_direction;
	vec4 sun_color;
	vec4 ambient_sky;
	vec4 ambient_ground;
	vec4 fog_color;
	vec4 fog_params;
	vec4 wind;
	vec4 wind_params;
	vec4 user[4];
};

layout(std140) uniform Material {
	vec4 tint;
	vec4 toon;
	vec4 rim_color;
	vec4 rim_params;
	vec4 specular;
	vec4 outline_color;
	vec4 outline_params;
	vec4 flags;
};

uniform sampler2D instance_data;
uniform sampler2D albedo_tex;
uniform sampler2D ramp_tex;

#define INSTANCES_PER_ROW 128
#define INSTANCE_TEXELS 8

VARYING vec3 v_world_pos;
VARYING vec3 v_normal;
VARYING vec2 v_uv;
VARYING vec4 v_color;
VARYING vec4 v_instance_tint;

#ifdef R3D_VERTEX

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec2 a_uv;
layout(location = 3) in vec4 a_color;
layout(location = 4) in uvec4 a_joints;
layout(location = 5) in vec4 a_weights;
layout(location = 6) in vec4 a_outline_normal;

vec4 fetch_instance(int instance, int k) {
	int x = (instance % INSTANCES_PER_ROW) * INSTANCE_TEXELS + k;
	int y = instance / INSTANCES_PER_ROW;
	return texelFetch(instance_data, ivec2(x, y), 0);
}

vec3 transform_point(vec4 r0, vec4 r1, vec4 r2, vec3 p) {
	return vec3(dot(r0.xyz, p) + r0.w, dot(r1.xyz, p) + r1.w, dot(r2.xyz, p) + r2.w);
}

vec3 transform_direction(vec4 r0, vec4 r1, vec4 r2, vec3 d) {
	return vec3(dot(r0.xyz, d), dot(r1.xyz, d), dot(r2.xyz, d));
}

void main() {
	vec4 r0 = fetch_instance(gl_InstanceID, 0);
	vec4 r1 = fetch_instance(gl_InstanceID, 1);
	vec4 r2 = fetch_instance(gl_InstanceID, 2);

	vec3 world = transform_point(r0, r1, r2, a_position);

#ifdef R3D_OUTLINE
	vec3 base_normal = a_outline_normal.xyz;
	if (dot(base_normal, base_normal) < 0.001) {
		base_normal = a_normal;
	}

	vec3 world_normal = normalize(transform_direction(r0, r1, r2, base_normal));
	vec4 clip = view_proj * vec4(world, 1.0);
	vec4 clip_pushed = view_proj * vec4(world + world_normal, 1.0);
	vec2 direction = clip_pushed.xy / clip_pushed.w - clip.xy / clip.w;
	direction = normalize(direction + vec2(1e-6, 0.0));
	clip.xy += direction * outline_params.x * 2.0 * viewport.zw * clip.w;
	v_normal = world_normal;
#else
	vec4 clip = view_proj * vec4(world, 1.0);
	v_normal = normalize(transform_direction(r0, r1, r2, a_normal));
#endif

	v_world_pos = world;
	v_uv = a_uv;
	v_color = a_color;
	v_instance_tint = fetch_instance(gl_InstanceID, 3);
	gl_Position = clip;
}

#endif

#ifdef R3D_FRAGMENT

layout(location = 0) out vec4 frag_color;

float fog_amount(float dist) {
	return clamp(1.0 - exp2(-fog_params.x * max(dist - fog_params.y, 0.0)), 0.0, 1.0);
}

#ifdef R3D_OUTLINE

void main() {
	vec3 color = outline_color.rgb;

	if (fog_params.x > 0.0) {
		float dist = length(camera_position.xyz - v_world_pos);
		color = mix(color, fog_color.rgb, fog_amount(dist));
	}

	frag_color = vec4(color, outline_color.a);
}

#else

float toon_light(float t) {
	if (toon.z > 0.5) {
		return texture(ramp_tex, vec2(t, 0.5)).r;
	}

	float bands = max(toon.x, 1.0);
	float x = clamp(t, 0.0, 1.0) * bands;
	float soft = clamp(toon.y * bands, 0.001, 0.5);
	return clamp((floor(x) + smoothstep(1.0 - soft, 1.0, fract(x))) / bands, 0.0, 1.0);
}

void main() {
	vec4 base = tint * v_instance_tint;

	if (flags.x > 0.5) {
		base *= texture(albedo_tex, v_uv);
	}

	if (flags.y > 0.5) {
		base *= v_color;
	}

	if (flags.z > 0.0 && base.a < flags.z) {
		discard;
	}

	if (flags.w > 0.5) {
		frag_color = base;
		return;
	}

	vec3 n = normalize(v_normal);
	vec3 view_vec = camera_position.xyz - v_world_pos;
	float dist = length(view_vec);
	vec3 v = view_vec / max(dist, 0.0001);
	vec3 l = sun_direction.xyz;
	float ndl = dot(n, l);

	float lit = toon_light(ndl * 0.5 + 0.5);
	float shade = mix(toon.w, 1.0, lit);
	vec3 ambient = mix(ambient_ground.rgb, ambient_sky.rgb, n.y * 0.5 + 0.5);
	vec3 color = base.rgb * (ambient * (1.0 - 0.5 * lit) + sun_color.rgb * shade);

	if (specular.a > 0.0) {
		vec3 h = normalize(l + v);
		float s = pow(clamp(dot(n, h), 0.0, 1.0), specular.a);
		color += specular.rgb * smoothstep(0.5, 0.55, s) * lit;
	}

	float rim = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), max(rim_color.a, 0.001));
	rim = smoothstep(rim_params.x, rim_params.x + max(rim_params.y, 0.001), rim);
	color += rim_color.rgb * rim * clamp(ndl * 0.5 + 0.5, 0.0, 1.0);

	if (fog_params.x > 0.0) {
		color = mix(color, fog_color.rgb, fog_amount(dist));
	}

	frag_color = vec4(color, base.a);
}

#endif

#endif
