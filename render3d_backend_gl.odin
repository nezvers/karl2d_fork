// RENDER3D: 3D backend for desktop OpenGL (3.3 core shaders). Owns its programs, buffers and sampler objects, uses the context, framebuffers and textures of the karl2d GL backend, and puts back the few GL states the karl2d GL backend assumes stay as it set them at init.
#+build windows, darwin, linux
#+private package
package karl2d

import gl "vendor:OpenGL"
import hm "core:container/handle_map"
import "base:runtime"
import "core:log"
import "core:math"
import "core:strings"

R3D_BACKEND_GL :: R3d_Backend_Interface {
	state_type = R3d_GL_State,
	init = r3d_gl_init,
	shutdown = r3d_gl_shutdown,
	create_mesh = r3d_gl_create_mesh,
	upload_lights = r3d_gl_upload_lights,
	destroy_mesh = r3d_gl_destroy_mesh,
	begin_pass = r3d_gl_begin_pass,
	end_pass = r3d_gl_end_pass,
	draw = r3d_gl_draw,
	read_pixels = r3d_gl_read_pixels,
}

R3D_MESH_SHADER_GL :: #load("render3d_shaders/r3d_mesh.glsl", string)

R3d_GL_State :: struct {
	using _: R3d_Backend_State,
	rb: ^GL_State,
	allocator: runtime.Allocator,
	max_instances: int,

	programs: [R3d_Pass]u32,
	globals_buffer: u32,
	material_buffer: u32,
	instance_texture: u32,
	white_texture: u32,
	light_textures: [3]u32,
	sampler_point: u32,
	sampler_linear: u32,

	flip_y: bool,
}

r3d_gl_build_program :: proc(pass: R3d_Pass) -> (program: u32, ok: bool) {
	header := "#version 330 core\n"
	outline := "#define R3D_OUTLINE\n" if pass == .Outline else ""
	vertex := strings.concatenate({header, "#define R3D_VERTEX\n", outline, R3D_MESH_SHADER_GL}, context.temp_allocator)
	fragment := strings.concatenate({header, "#define R3D_FRAGMENT\n", outline, R3D_MESH_SHADER_GL}, context.temp_allocator)
	return gl.load_shaders_source(vertex, fragment)
}

r3d_gl_init :: proc(s: ^R3d_GL_State, rb_state: ^Render_Backend_State, max_instances: int, allocator: runtime.Allocator) -> bool {
	s.rb = (^GL_State)(rb_state)
	s.allocator = allocator
	s.max_instances = max_instances

	for pass in R3d_Pass {
		program, ok := r3d_gl_build_program(pass)

		if !ok {
			log.errorf("The 3D shader for pass %v failed to build", pass)
			return false
		}

		s.programs[pass] = program
		gl.UseProgram(program)
		gl.Uniform1i(gl.GetUniformLocation(program, "instance_data"), 0)
		gl.Uniform1i(gl.GetUniformLocation(program, "albedo_tex"), 1)
		gl.Uniform1i(gl.GetUniformLocation(program, "ramp_tex"), 2)
		gl.Uniform1i(gl.GetUniformLocation(program, "light_data"), 3)
		gl.Uniform1i(gl.GetUniformLocation(program, "cluster_grid"), 4)
		gl.Uniform1i(gl.GetUniformLocation(program, "light_indices"), 5)
		gl.UniformBlockBinding(program, gl.GetUniformBlockIndex(program, "Globals"), 0)
		gl.UniformBlockBinding(program, gl.GetUniformBlockIndex(program, "Material"), 1)
	}

	gl.UseProgram(0)

	gl.GenBuffers(1, &s.globals_buffer)
	gl.BindBuffer(gl.UNIFORM_BUFFER, s.globals_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(R3d_Globals), nil, gl.DYNAMIC_DRAW)

	gl.GenBuffers(1, &s.material_buffer)
	gl.BindBuffer(gl.UNIFORM_BUFFER, s.material_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(R3d_Material_Constants), nil, gl.DYNAMIC_DRAW)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)

	rows := (max_instances + R3D_INSTANCES_PER_ROW - 1) / R3D_INSTANCES_PER_ROW
	gl.GenTextures(1, &s.instance_texture)
	gl.BindTexture(gl.TEXTURE_2D, s.instance_texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, R3D_INSTANCE_ROW_TEXELS, i32(rows), 0, gl.RGBA, gl.FLOAT, nil)

	white := [4]u8{255, 255, 255, 255}
	gl.GenTextures(1, &s.white_texture)
	gl.BindTexture(gl.TEXTURE_2D, s.white_texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &white[0])
	gl.BindTexture(gl.TEXTURE_2D, 0)

	for i in 0 ..< 3 {
		gl.GenTextures(1, &s.light_textures[i])
		gl.BindTexture(gl.TEXTURE_2D, s.light_textures[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, R3D_DATA_TEXTURE_WIDTH, R3D_DATA_TEXTURE_HEIGHT, 0, gl.RGBA, gl.FLOAT, nil)
	}

	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.GenSamplers(1, &s.sampler_point)
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenSamplers(1, &s.sampler_linear)
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_WRAP_T, gl.REPEAT)

	return true
}

r3d_gl_shutdown :: proc(s: ^R3d_GL_State) {
	for program in s.programs {
		gl.DeleteProgram(program)
	}

	gl.DeleteBuffers(1, &s.globals_buffer)
	gl.DeleteBuffers(1, &s.material_buffer)
	gl.DeleteTextures(1, &s.instance_texture)
	gl.DeleteTextures(1, &s.white_texture)
	gl.DeleteTextures(3, &s.light_textures[0])
	gl.DeleteSamplers(1, &s.sampler_point)
	gl.DeleteSamplers(1, &s.sampler_linear)
}

r3d_gl_create_mesh :: proc(s: ^R3d_GL_State, vertices: []R3d_Vertex, indices: []u32) -> (R3d_Backend_Mesh, bool) {
	mesh: R3d_Backend_Mesh
	vertex_buffer, index_buffer: u32

	gl.GenVertexArrays(1, &mesh.vertex_array)
	gl.BindVertexArray(mesh.vertex_array)

	gl.GenBuffers(1, &vertex_buffer)
	gl.BindBuffer(gl.ARRAY_BUFFER, vertex_buffer)
	gl.BufferData(gl.ARRAY_BUFFER, len(vertices) * size_of(R3d_Vertex), raw_data(vertices), gl.STATIC_DRAW)

	stride := i32(size_of(R3d_Vertex))
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 3, gl.FLOAT, false, stride, offset_of(R3d_Vertex, position))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, false, stride, offset_of(R3d_Vertex, normal))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribPointer(2, 2, gl.FLOAT, false, stride, offset_of(R3d_Vertex, uv))
	gl.EnableVertexAttribArray(3)
	gl.VertexAttribPointer(3, 4, gl.UNSIGNED_BYTE, true, stride, offset_of(R3d_Vertex, color))
	gl.EnableVertexAttribArray(4)
	gl.VertexAttribIPointer(4, 4, gl.UNSIGNED_BYTE, stride, offset_of(R3d_Vertex, joints))
	gl.EnableVertexAttribArray(5)
	gl.VertexAttribPointer(5, 4, gl.UNSIGNED_BYTE, true, stride, offset_of(R3d_Vertex, weights))
	gl.EnableVertexAttribArray(6)
	gl.VertexAttribPointer(6, 4, gl.BYTE, true, stride, offset_of(R3d_Vertex, outline_normal))

	gl.GenBuffers(1, &index_buffer)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, index_buffer)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(indices) * size_of(u32), raw_data(indices), gl.STATIC_DRAW)

	gl.BindVertexArray(0)
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)

	mesh.vertex_buffer = rawptr(uintptr(vertex_buffer))
	mesh.index_buffer = rawptr(uintptr(index_buffer))
	mesh.vertex_count = len(vertices)
	mesh.index_count = len(indices)
	return mesh, true
}

r3d_gl_destroy_mesh :: proc(s: ^R3d_GL_State, mesh: R3d_Backend_Mesh) {
	vertex_buffer := u32(uintptr(mesh.vertex_buffer))
	index_buffer := u32(uintptr(mesh.index_buffer))
	vertex_array := mesh.vertex_array
	gl.DeleteBuffers(1, &vertex_buffer)
	gl.DeleteBuffers(1, &index_buffer)
	gl.DeleteVertexArrays(1, &vertex_array)
}

r3d_gl_upload_lights :: proc(s: ^R3d_GL_State, textures: ^R3d_Light_Textures) {
	sources := [3]^R3d_Data_Texture{&textures.lights, &textures.grid, &textures.indices}
	gl.ActiveTexture(gl.TEXTURE3)

	for source, i in sources {
		gl.BindTexture(gl.TEXTURE_2D, s.light_textures[i])
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, R3D_DATA_TEXTURE_WIDTH, R3D_DATA_TEXTURE_HEIGHT, gl.RGBA, gl.FLOAT, &source[0])
	}

	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.ActiveTexture(gl.TEXTURE0)
}

r3d_gl_begin_pass :: proc(s: ^R3d_GL_State, target: Render_Target_Handle, width, height: int, flip_y: bool, globals: ^R3d_Globals) {
	s.flip_y = flip_y

	if rt := hm.get(&s.rb.render_targets, target); rt != nil {
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.framebuffer)
		gl.Viewport(0, 0, i32(rt.width), i32(rt.height))
	} else {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		gl.Viewport(0, 0, i32(s.rb.width), i32(s.rb.height))
	}

	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.GEQUAL)
	gl.DepthMask(true)
	gl.Enable(gl.CULL_FACE)
	gl.FrontFace(gl.CCW)

	gl.BindBuffer(gl.UNIFORM_BUFFER, s.globals_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(R3d_Globals), globals, gl.DYNAMIC_DRAW)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, s.globals_buffer)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 1, s.material_buffer)

	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, s.instance_texture)
	gl.BindSampler(0, s.sampler_point)
	gl.BindSampler(1, s.sampler_linear)
	gl.BindSampler(2, s.sampler_linear)

	for i in 0 ..< 3 {
		gl.ActiveTexture(u32(gl.TEXTURE3 + i))
		gl.BindTexture(gl.TEXTURE_2D, s.light_textures[i])
		gl.BindSampler(u32(3 + i), s.sampler_point)
	}

	gl.ActiveTexture(gl.TEXTURE0)
}

r3d_gl_end_pass :: proc(s: ^R3d_GL_State) {
	for unit in 0 ..< 6 {
		gl.ActiveTexture(u32(gl.TEXTURE0 + unit))
		gl.BindTexture(gl.TEXTURE_2D, 0)
		gl.BindSampler(u32(unit), 0)
	}

	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindVertexArray(0)
	gl.UseProgram(0)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, 0)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 1, 0)
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.DepthFunc(gl.GEQUAL)
	gl.DepthMask(true)
}

r3d_gl_native_texture :: proc(s: ^R3d_GL_State, texture: Render_Backend_Texture) -> u32 {
	if tex := hm.get(&s.rb.textures, texture); tex != nil {
		return tex.id
	}

	return s.white_texture
}

r3d_gl_draw :: proc(
	s: ^R3d_GL_State,
	mesh: R3d_Backend_Mesh,
	pass: R3d_Pass,
	material: ^R3d_Material_Constants,
	albedo: Render_Backend_Texture,
	ramp: Render_Backend_Texture,
	instances: []R3d_Instance,
) {
	count := min(len(instances), s.max_instances)

	gl.BindBuffer(gl.UNIFORM_BUFFER, s.material_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(R3d_Material_Constants), material, gl.DYNAMIC_DRAW)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 1, s.material_buffer)

	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, s.instance_texture)

	full_rows := count / R3D_INSTANCES_PER_ROW
	rest := count % R3D_INSTANCES_PER_ROW

	if full_rows > 0 {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, R3D_INSTANCE_ROW_TEXELS, i32(full_rows), gl.RGBA, gl.FLOAT, raw_data(instances))
	}

	if rest > 0 {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, i32(full_rows), i32(rest * R3D_INSTANCE_TEXELS), 1, gl.RGBA, gl.FLOAT, &instances[full_rows * R3D_INSTANCES_PER_ROW])
	}

	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, r3d_gl_native_texture(s, albedo))
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, r3d_gl_native_texture(s, ramp))
	gl.ActiveTexture(gl.TEXTURE0)

	cull_back := pass == .Main
	if s.flip_y {
		cull_back = !cull_back
	}
	gl.CullFace(gl.BACK if cull_back else gl.FRONT)

	gl.UseProgram(s.programs[pass])
	gl.BindVertexArray(mesh.vertex_array)
	gl.DrawElementsInstanced(gl.TRIANGLES, i32(mesh.index_count), gl.UNSIGNED_INT, nil, i32(count))
}

r3d_gl_read_pixels :: proc(s: ^R3d_GL_State, target: Render_Target_Handle, width, height: int, out_rgba8: []u8) -> bool {
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)

	if rt := hm.get(&s.rb.render_targets, target); rt != nil {
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.framebuffer)
		pixels := make([]f32, width * height * 4, context.temp_allocator)
		gl.ReadPixels(0, 0, i32(width), i32(height), gl.RGBA, gl.FLOAT, raw_data(pixels))
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

		for i in 0 ..< width * height * 4 {
			out_rgba8[i] = u8(math.round(clamp(pixels[i], 0, 1) * 255))
		}

		return true
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	gl.ReadPixels(0, 0, i32(width), i32(height), gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))

	for y in 0 ..< height {
		source := pixels[(height - 1 - y) * width * 4:][:width * 4]
		copy(out_rgba8[y * width * 4:][:width * 4], source)
	}

	return true
}
