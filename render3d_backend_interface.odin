// RENDER3D: the backend of the 3D layer. One implementation per karl2d render backend, each in its own new file. They share the device, window, swapchain and render targets of the karl2d backend through its state pointer, and own everything else.
package karl2d

import "base:runtime"

R3d_Backend_State :: struct {}

R3d_Backend_Interface :: struct #all_or_none {
	state_type: typeid,

	init: proc(
		s: ^R3d_Backend_State,
		rb_state: ^Render_Backend_State,
		max_instances: int,
		allocator: runtime.Allocator,
	) -> bool,

	shutdown: proc(s: ^R3d_Backend_State),

	create_mesh: proc(
		s: ^R3d_Backend_State,
		vertices: []R3d_Vertex,
		indices: []u32,
	) -> (R3d_Backend_Mesh, bool),

	destroy_mesh: proc(s: ^R3d_Backend_State, mesh: R3d_Backend_Mesh),

	upload_lights: proc(s: ^R3d_Backend_State, textures: ^R3d_Light_Textures),

	begin_pass: proc(
		s: ^R3d_Backend_State,
		target: Render_Target_Handle,
		width: int,
		height: int,
		flip_y: bool,
		globals: ^R3d_Globals,
	),

	end_pass: proc(s: ^R3d_Backend_State),

	draw: proc(
		s: ^R3d_Backend_State,
		mesh: R3d_Backend_Mesh,
		pass: R3d_Pass,
		material: ^R3d_Material_Constants,
		albedo: Render_Backend_Texture,
		ramp: Render_Backend_Texture,
		instances: []R3d_Instance,
	),

	read_pixels: proc(
		s: ^R3d_Backend_State,
		target: Render_Target_Handle,
		width: int,
		height: int,
		out_rgba8: []u8,
	) -> bool,
}
