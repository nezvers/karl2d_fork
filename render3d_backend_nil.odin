// RENDER3D: 3D backend that draws nothing and counts what it was asked to draw, for tests and for backends without a 3D implementation.
#+private package
package karl2d

import "base:runtime"

R3D_BACKEND_NIL :: R3d_Backend_Interface {
	state_type = R3d_Nil_State,
	init = r3d_nil_init,
	shutdown = r3d_nil_shutdown,
	create_mesh = r3d_nil_create_mesh,
	destroy_mesh = r3d_nil_destroy_mesh,
	upload_lights = r3d_nil_upload_lights,
	begin_pass = r3d_nil_begin_pass,
	end_pass = r3d_nil_end_pass,
	draw = r3d_nil_draw,
	read_pixels = r3d_nil_read_pixels,
}

R3d_Nil_State :: struct {
	using _: R3d_Backend_State,
	passes: int,
	draws: [R3d_Pass]int,
	instances: int,
	triangles: int,
	meshes_alive: int,
	last_globals: R3d_Globals,
	last_flip_y: bool,
	light_uploads: int,
}

r3d_nil_init :: proc(s: ^R3d_Nil_State, rb_state: ^Render_Backend_State, max_instances: int, allocator: runtime.Allocator) -> bool {
	return true
}

r3d_nil_shutdown :: proc(s: ^R3d_Nil_State) {
}

r3d_nil_create_mesh :: proc(s: ^R3d_Nil_State, vertices: []R3d_Vertex, indices: []u32) -> (R3d_Backend_Mesh, bool) {
	s.meshes_alive += 1
	return {vertex_count = len(vertices), index_count = len(indices)}, true
}

r3d_nil_destroy_mesh :: proc(s: ^R3d_Nil_State, mesh: R3d_Backend_Mesh) {
	s.meshes_alive -= 1
}

r3d_nil_upload_lights :: proc(s: ^R3d_Nil_State, textures: ^R3d_Light_Textures) {
	s.light_uploads += 1
}

r3d_nil_begin_pass :: proc(s: ^R3d_Nil_State, target: Render_Target_Handle, width, height: int, flip_y: bool, globals: ^R3d_Globals) {
	s.passes += 1
	s.last_globals = globals^
	s.last_flip_y = flip_y
}

r3d_nil_end_pass :: proc(s: ^R3d_Nil_State) {
}

r3d_nil_draw :: proc(
	s: ^R3d_Nil_State,
	mesh: R3d_Backend_Mesh,
	pass: R3d_Pass,
	material: ^R3d_Material_Constants,
	albedo: Render_Backend_Texture,
	ramp: Render_Backend_Texture,
	instances: []R3d_Instance,
) {
	s.draws[pass] += 1
	s.instances += len(instances)
	s.triangles += mesh.index_count / 3 * len(instances)
}

r3d_nil_read_pixels :: proc(s: ^R3d_Nil_State, target: Render_Target_Handle, width, height: int, out_rgba8: []u8) -> bool {
	return false
}
