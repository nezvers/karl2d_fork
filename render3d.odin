// RENDER3D: public API of the stylized 3D forward renderer. New file, it only reads karl2d through get_internal_state() (see render3d_internal.odin and RENDER3D.md).
package karl2d

import hm "core:container/handle_map"
import "base:runtime"
import "core:log"
import "core:math/linalg"

R3d_Stats :: struct {
	passes: int,
	draw_calls: int,
	instances: int,
	triangles: int,
}

R3d_State :: struct {
	allocator: runtime.Allocator,
	backend: R3d_Backend_Interface,
	backend_state: ^R3d_Backend_State,
	meshes: hm.Dynamic_Handle_Map(R3d_Mesh_Object, R3d_Mesh),
	max_instances: int,
	in_scene: bool,
	stats: R3d_Stats,
}

@(private="file")
r3d: ^R3d_State

r3d_init :: proc(max_instances := R3D_DEFAULT_MAX_INSTANCES, allocator := context.allocator) -> bool {
	assert(r3d == nil, "r3d_init called twice")
	ks := r3d_karl2d_state()

	if !ks.depth_test {
		log.error("r3d_init needs Init_Options.depth_test = true, the 3D layer shares the depth buffer of karl2d")
		return false
	}

	if !R3D_BACKEND_AVAILABLE {
		log.warnf("The 3D layer has no implementation for the '%v' render backend yet, 3D draws are ignored", RENDER_BACKEND_NAME)
	}

	r3d = new(R3d_State, allocator)
	r3d.allocator = allocator
	r3d.backend = R3D_BACKEND
	r3d.max_instances = max(max_instances, R3D_INSTANCES_PER_ROW)
	hm.dynamic_init(&r3d.meshes, allocator)

	backend_state, state_err := mem_alloc_state(r3d.backend.state_type, allocator)

	if state_err != nil {
		log.errorf("Could not allocate the 3D backend state: %v", state_err)
		free(r3d, allocator)
		r3d = nil
		return false
	}

	r3d.backend_state = (^R3d_Backend_State)(backend_state)

	if !r3d.backend.init(r3d.backend_state, ks.rb_state, r3d.max_instances, allocator) {
		log.error("The 3D backend failed to initialize")
		free(backend_state, allocator)
		hm.dynamic_destroy(&r3d.meshes)
		free(r3d, allocator)
		r3d = nil
		return false
	}

	return true
}

r3d_shutdown :: proc() {
	if r3d == nil {
		return
	}

	for mesh_iter := hm.iterator_make(&r3d.meshes); mesh, _ in hm.iterate(&mesh_iter) {
		r3d.backend.destroy_mesh(r3d.backend_state, mesh.native)
	}

	r3d.backend.shutdown(r3d.backend_state)
	free(r3d.backend_state, r3d.allocator)
	hm.dynamic_destroy(&r3d.meshes)
	allocator := r3d.allocator
	free(r3d, allocator)
	r3d = nil
}

r3d_mesh_create :: proc(vertices: []R3d_Vertex, indices: []u32) -> (R3d_Mesh, bool) {
	if len(vertices) == 0 || len(indices) == 0 || len(indices) % 3 != 0 {
		log.error("r3d_mesh_create needs vertices and a whole number of triangles")
		return R3D_MESH_NONE, false
	}

	native, ok := r3d.backend.create_mesh(r3d.backend_state, vertices, indices)

	if !ok {
		return R3D_MESH_NONE, false
	}

	handle, add_err := hm.add(&r3d.meshes, R3d_Mesh_Object{native = native})

	if add_err != nil {
		log.errorf("Failed creating mesh. Error: %v", add_err)
		r3d.backend.destroy_mesh(r3d.backend_state, native)
		return R3D_MESH_NONE, false
	}

	return handle, true
}

r3d_mesh_create_from_data :: proc(data: R3d_Mesh_Data) -> (R3d_Mesh, bool) {
	return r3d_mesh_create(data.vertices[:], data.indices[:])
}

r3d_mesh_destroy :: proc(mesh: R3d_Mesh) {
	if object := hm.get(&r3d.meshes, mesh); object != nil {
		r3d.backend.destroy_mesh(r3d.backend_state, object.native)
		hm.remove(&r3d.meshes, mesh)
	}
}

r3d_stats :: proc() -> R3d_Stats {
	return r3d.stats
}

r3d_reset_stats :: proc() {
	r3d.stats = {}
}

r3d_begin_scene :: proc(camera: R3d_Camera, environment: R3d_Environment) {
	assert(!r3d.in_scene, "r3d_begin_scene called twice without r3d_end_scene")
	ks := r3d_karl2d_state()

	draw_current_batch()

	target := ks.current_render_target
	width, height: int

	if target == RENDER_TARGET_NONE {
		width, height = get_screen_width(), get_screen_height()
	} else {
		width, height = ks.current_render_target_width, ks.current_render_target_height
	}

	clip_min, clip_max := ks.rb.get_depth_clip_range()
	view, projection := r3d_camera_matrices(camera, f32(width) / f32(max(height, 1)), clip_min, clip_max)
	flip_y := target != RENDER_TARGET_NONE && ks.rb.flip_render_textures

	if flip_y {
		projection[1, 1] = -projection[1, 1]
	}

	globals := r3d_make_globals(camera, environment, view, projection, width, height)
	r3d.backend.begin_pass(r3d.backend_state, target, width, height, flip_y, &globals)
	r3d.in_scene = true
	r3d.stats.passes += 1
}

r3d_end_scene :: proc() {
	assert(r3d.in_scene, "r3d_end_scene without r3d_begin_scene")
	r3d.backend.end_pass(r3d.backend_state)
	r3d.in_scene = false
	r3d_karl2d_state().draw_call_changes = DRAW_CALL_CHANGE_ALL
}

r3d_draw :: proc(mesh: R3d_Mesh, material: R3d_Material, instances: []R3d_Instance) {
	assert(r3d.in_scene, "r3d_draw outside r3d_begin_scene / r3d_end_scene")
	object := hm.get(&r3d.meshes, mesh)

	if object == nil || len(instances) == 0 {
		return
	}

	ks := r3d_karl2d_state()
	constants := r3d_make_material_constants(material)
	albedo, ramp: Render_Backend_Texture

	if tex := hm.get(&ks.textures, material.albedo); tex != nil {
		albedo = tex.rb_texture
	}

	if tex := hm.get(&ks.textures, material.ramp); tex != nil {
		ramp = tex.rb_texture
	}

	rest := instances

	for len(rest) > 0 {
		count := min(len(rest), r3d.max_instances)
		chunk := rest[:count]
		rest = rest[count:]

		r3d.backend.draw(r3d.backend_state, object.native, .Main, &constants, albedo, ramp, chunk)
		r3d.stats.draw_calls += 1
		r3d.stats.instances += count
		r3d.stats.triangles += object.native.index_count / 3 * count

		if material.outline_width > 0 {
			r3d.backend.draw(r3d.backend_state, object.native, .Outline, &constants, albedo, ramp, chunk)
			r3d.stats.draw_calls += 1
		}
	}
}

r3d_draw_one :: proc(mesh: R3d_Mesh, material: R3d_Material, transform: Mat4, tint: [4]f32 = {1, 1, 1, 1}) {
	instance := r3d_instance_from_matrix(transform, tint)
	r3d_draw(mesh, material, {instance})
}

r3d_read_pixels :: proc(target: Render_Texture, allocator := context.allocator) -> (pixels: []u8, width: int, height: int, ok: bool) {
	ks := r3d_karl2d_state()
	draw_current_batch()

	if target.render_target == RENDER_TARGET_NONE {
		width, height = get_screen_width(), get_screen_height()
	} else {
		tex := hm.get(&ks.textures, target.texture)

		if tex == nil {
			return nil, 0, 0, false
		}

		width, height = tex.width, tex.height
	}

	pixels = make([]u8, width * height * 4, allocator)
	ok = r3d.backend.read_pixels(r3d.backend_state, target.render_target, width, height, pixels)

	if !ok {
		delete(pixels, allocator)
		return nil, 0, 0, false
	}

	return pixels, width, height, true
}

@(private="file")
r3d_make_globals :: proc(camera: R3d_Camera, env: R3d_Environment, view, projection: Mat4, width, height: int) -> R3d_Globals {
	g: R3d_Globals
	g.view = view
	g.view_proj = projection * view
	g.camera_position = {camera.position.x, camera.position.y, camera.position.z, 1}
	g.time = {f32(get_time()), get_frame_time(), 0, 0}
	g.viewport = {f32(width), f32(height), 1 / f32(max(width, 1)), 1 / f32(max(height, 1))}

	sun := env.sun_direction
	if linalg.length2(sun) > 1e-8 {
		sun = linalg.normalize(sun)
	}

	g.sun_direction = {sun.x, sun.y, sun.z, 0}
	g.sun_color = {env.sun_color.x, env.sun_color.y, env.sun_color.z, 1}
	g.ambient_sky = {env.ambient_sky.x, env.ambient_sky.y, env.ambient_sky.z, 1}
	g.ambient_ground = {env.ambient_ground.x, env.ambient_ground.y, env.ambient_ground.z, 1}
	g.fog_color = {env.fog_color.x, env.fog_color.y, env.fog_color.z, 1}
	g.fog_params = {env.fog_density, env.fog_start, env.fog_height_falloff, 0}

	wind := env.wind_direction
	if linalg.length2(wind) > 1e-8 {
		wind = linalg.normalize(wind) * env.wind_strength
	}

	g.wind = {wind.x, wind.y, wind.z, env.wind_frequency}
	g.wind_params = {env.wind_gust, 0, 0, 0}
	g.user = env.user
	return g
}

@(private="file")
r3d_make_material_constants :: proc(m: R3d_Material) -> R3d_Material_Constants {
	c: R3d_Material_Constants
	c.tint = m.tint
	c.toon = {m.toon_bands, m.toon_softness, m.toon_ramp_mix, m.shade_floor}
	c.rim_color = {m.rim_color.x, m.rim_color.y, m.rim_color.z, m.rim_power}
	c.rim_params = {m.rim_threshold, m.rim_softness, 0, 0}
	c.specular = {m.specular_color.x, m.specular_color.y, m.specular_color.z, m.specular_power}
	c.outline_color = m.outline_color
	c.outline_params = {m.outline_width, 0, 0, 0}
	c.flags = {
		1 if m.albedo != TEXTURE_NONE else 0,
		1 if m.use_vertex_color else 0,
		m.cutout,
		1 if m.unlit else 0,
	}
	return c
}

@(private="file")
mem_alloc_state :: proc(type: typeid, allocator: runtime.Allocator) -> (rawptr, runtime.Allocator_Error) {
	ti := type_info_of(type)
	memory, err := runtime.mem_alloc(ti.size, ti.align, allocator)
	return raw_data(memory), err
}
