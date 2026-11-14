// RENDER3D: types of the 3D layer (see RENDER3D.md). New file, no upstream lines changed.
package karl2d

R3D_INSTANCE_TEXELS :: 8
R3D_INSTANCE_ROW_TEXELS :: 1024
R3D_INSTANCES_PER_ROW :: R3D_INSTANCE_ROW_TEXELS / R3D_INSTANCE_TEXELS
R3D_DEFAULT_MAX_INSTANCES :: 16384

R3d_Mesh :: distinct Handle

R3d_Vertex :: struct {
	position: Vec3,
	normal: Vec3,
	uv: Vec2,
	color: Color,
	joints: [4]u8,
	weights: [4]u8,
	outline_normal: [4]i8,
}

R3d_Instance :: struct {
	row0: [4]f32,
	row1: [4]f32,
	row2: [4]f32,
	tint: [4]f32,
	params: [4][4]f32,
}

#assert(size_of(R3d_Instance) == R3D_INSTANCE_TEXELS * 16)
#assert(size_of(R3d_Vertex) == 48)

R3d_Camera :: struct {
	position: Vec3,
	target: Vec3,
	up: Vec3,
	fov_y_degrees: f32,
	near: f32,
	far: f32,
	orthographic: bool,
	ortho_height: f32,
}

R3d_Environment :: struct {
	sun_direction: Vec3,
	sun_color: Vec3,
	ambient_sky: Vec3,
	ambient_ground: Vec3,
	fog_color: Vec3,
	fog_density: f32,
	fog_start: f32,
	fog_height_falloff: f32,
	wind_direction: Vec3,
	wind_strength: f32,
	wind_frequency: f32,
	wind_gust: f32,
	time_override: Maybe(f32),
	user: [4][4]f32,
}

R3d_Material :: struct {
	tint: [4]f32,
	albedo: Texture,
	ramp: Texture,
	toon_bands: f32,
	toon_softness: f32,
	toon_ramp_mix: f32,
	shade_floor: f32,
	rim_color: Vec3,
	rim_power: f32,
	rim_threshold: f32,
	rim_softness: f32,
	specular_color: Vec3,
	specular_power: f32,
	outline_color: [4]f32,
	outline_width: f32,
	use_vertex_color: bool,
	unlit: bool,
	cutout: f32,
	wind_weight: f32,
	wind_height: f32,
}

R3d_Globals :: struct #align(16) {
	view_proj: matrix[4,4]f32,
	view: matrix[4,4]f32,
	camera_position: [4]f32,
	time: [4]f32,
	viewport: [4]f32,
	sun_direction: [4]f32,
	sun_color: [4]f32,
	ambient_sky: [4]f32,
	ambient_ground: [4]f32,
	fog_color: [4]f32,
	fog_params: [4]f32,
	wind: [4]f32,
	wind_params: [4]f32,
	lights: [4]f32,
	cluster: [4]f32,
	user: [4][4]f32,
}

R3d_Material_Constants :: struct #align(16) {
	tint: [4]f32,
	toon: [4]f32,
	rim_color: [4]f32,
	rim_params: [4]f32,
	specular: [4]f32,
	outline_color: [4]f32,
	outline_params: [4]f32,
	flags: [4]f32,
	wind: [4]f32,
}

#assert(size_of(R3d_Globals) % 16 == 0)
#assert(size_of(R3d_Material_Constants) == 144)

R3d_Pass :: enum {
	Main,
	Outline,
}

R3d_Backend_Mesh :: struct {
	vertex_buffer: rawptr,
	index_buffer: rawptr,
	vertex_array: u32,
	vertex_count: int,
	index_count: int,
}

R3d_Mesh_Object :: struct {
	handle: R3d_Mesh,
	native: R3d_Backend_Mesh,
}

R3D_MESH_NONE :: R3d_Mesh {}

r3d_material_default :: proc() -> R3d_Material {
	return {
		tint = {1, 1, 1, 1},
		toon_bands = 3,
		toon_softness = 0.04,
		shade_floor = 0.25,
		rim_color = {0.8, 0.9, 1},
		rim_power = 3,
		rim_threshold = 0.55,
		rim_softness = 0.08,
		specular_power = 0,
		outline_color = {0.05, 0.04, 0.07, 1},
		outline_width = 0,
		cutout = 0,
		wind_height = 1,
	}
}

r3d_environment_default :: proc() -> R3d_Environment {
	return {
		sun_direction = {0.4, 0.8, 0.5},
		sun_color = {1, 0.96, 0.88},
		ambient_sky = {0.45, 0.55, 0.75},
		ambient_ground = {0.25, 0.22, 0.2},
		fog_color = {0.7, 0.78, 0.9},
		fog_density = 0,
		fog_start = 20,
		wind_direction = {1, 0, 0.3},
		wind_strength = 0.3,
		wind_frequency = 0.8,
		wind_gust = 0.5,
	}
}
