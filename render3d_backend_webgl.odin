// RENDER3D: 3D backend for WebGL2 (html5 export). The same design and the same shader source as the desktop GL backend, with the WebGL binding types and a GLSL ES 3.00 header. Owns its programs, buffers and samplers, uses the canvas context, framebuffers and textures of the karl2d WebGL backend.
#+build js
#+private package
package karl2d

import gl "vendor:wasm/WebGL"
import hm "core:container/handle_map"
import "base:runtime"
import "core:log"
import "core:math"
import "core:strings"

R3D_BACKEND_WEBGL :: R3d_Backend_Interface {
	state_type = R3d_WebGL_State,
	init = r3d_webgl_init,
	shutdown = r3d_webgl_shutdown,
	create_mesh = r3d_webgl_create_mesh,
	upload_lights = r3d_webgl_upload_lights,
	destroy_mesh = r3d_webgl_destroy_mesh,
	begin_pass = r3d_webgl_begin_pass,
	end_pass = r3d_webgl_end_pass,
	draw = r3d_webgl_draw,
	read_pixels = r3d_webgl_read_pixels,
}

R3D_MESH_SHADER_WEBGL :: #load("render3d_shaders/r3d_mesh.glsl", string)

R3d_WebGL_State :: struct {
	using _: R3d_Backend_State,
	rb: ^WebGL_State,
	allocator: runtime.Allocator,
	max_instances: int,

	programs: [R3d_Pass]gl.Program,
	globals_buffer: gl.Buffer,
	material_buffer: gl.Buffer,
	instance_texture: gl.Texture,
	white_texture: gl.Texture,
	light_textures: [3]gl.Texture,
	sampler_point: gl.Sampler,
	sampler_linear: gl.Sampler,

	flip_y: bool,
}

r3d_webgl_build_program :: proc(pass: R3d_Pass) -> (program: gl.Program, ok: bool) {
	header := "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
	outline := "#define R3D_OUTLINE\n" if pass == .Outline else ""
	vertex := strings.concatenate({header, "#define R3D_VERTEX\n", outline, R3D_MESH_SHADER_WEBGL}, context.temp_allocator)
	fragment := strings.concatenate({header, "#define R3D_FRAGMENT\n", outline, R3D_MESH_SHADER_WEBGL}, context.temp_allocator)
	return gl.CreateProgramFromStrings({vertex}, {fragment})
}

r3d_webgl_init :: proc(s: ^R3d_WebGL_State, rb_state: ^Render_Backend_State, max_instances: int, allocator: runtime.Allocator) -> bool {
	s.rb = (^WebGL_State)(rb_state)
	s.allocator = allocator
	s.max_instances = max_instances

	for pass in R3d_Pass {
		program, ok := r3d_webgl_build_program(pass)

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

	s.globals_buffer = gl.CreateBuffer()
	gl.BindBuffer(gl.UNIFORM_BUFFER, s.globals_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(R3d_Globals), nil, gl.DYNAMIC_DRAW)

	s.material_buffer = gl.CreateBuffer()
	gl.BindBuffer(gl.UNIFORM_BUFFER, s.material_buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(R3d_Material_Constants), nil, gl.DYNAMIC_DRAW)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)

	rows := (max_instances + R3D_INSTANCES_PER_ROW - 1) / R3D_INSTANCES_PER_ROW
	s.instance_texture = gl.CreateTexture()
	gl.BindTexture(gl.TEXTURE_2D, s.instance_texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, R3D_INSTANCE_ROW_TEXELS, i32(rows), 0, gl.RGBA, gl.FLOAT, 0, nil)

	white := [4]u8{255, 255, 255, 255}
	s.white_texture = gl.CreateTexture()
	gl.BindTexture(gl.TEXTURE_2D, s.white_texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, len(white), &white[0])
	gl.BindTexture(gl.TEXTURE_2D, 0)

	for i in 0 ..< 3 {
		s.light_textures[i] = gl.CreateTexture()
		gl.BindTexture(gl.TEXTURE_2D, s.light_textures[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, R3D_DATA_TEXTURE_WIDTH, R3D_DATA_TEXTURE_HEIGHT, 0, gl.RGBA, gl.FLOAT, 0, nil)
	}

	gl.BindTexture(gl.TEXTURE_2D, 0)

	s.sampler_point = gl.CreateSampler()
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.SamplerParameteri(s.sampler_point, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))

	s.sampler_linear = gl.CreateSampler()
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_MIN_FILTER, i32(gl.LINEAR))
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_MAG_FILTER, i32(gl.LINEAR))
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_WRAP_S, i32(gl.REPEAT))
	gl.SamplerParameteri(s.sampler_linear, gl.TEXTURE_WRAP_T, i32(gl.REPEAT))

	return true
}

r3d_webgl_shutdown :: proc(s: ^R3d_WebGL_State) {
	for program in s.programs {
		gl.DeleteProgram(program)
	}

	gl.DeleteBuffer(s.globals_buffer)
	gl.DeleteBuffer(s.material_buffer)
	gl.DeleteTexture(s.instance_texture)
	gl.DeleteTexture(s.white_texture)

	for texture in s.light_textures {
		gl.DeleteTexture(texture)
	}

	gl.DeleteSampler(s.sampler_point)
	gl.DeleteSampler(s.sampler_linear)
}

r3d_webgl_create_mesh :: proc(s: ^R3d_WebGL_State, vertices: []R3d_Vertex, indices: []u32) -> (R3d_Backend_Mesh, bool) {
	mesh: R3d_Backend_Mesh

	vertex_array := gl.CreateVertexArray()
	gl.BindVertexArray(vertex_array)

	vertex_buffer := gl.CreateBuffer()
	gl.BindBuffer(gl.ARRAY_BUFFER, vertex_buffer)
	gl.BufferData(gl.ARRAY_BUFFER, len(vertices) * size_of(R3d_Vertex), raw_data(vertices), gl.STATIC_DRAW)

	stride := size_of(R3d_Vertex)
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

	index_buffer := gl.CreateBuffer()
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, index_buffer)
	gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(indices) * size_of(u32), raw_data(indices), gl.STATIC_DRAW)

	gl.BindVertexArray(0)
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)

	mesh.vertex_array = u32(vertex_array)
	mesh.vertex_buffer = rawptr(uintptr(u32(vertex_buffer)))
	mesh.index_buffer = rawptr(uintptr(u32(index_buffer)))
	mesh.vertex_count = len(vertices)
	mesh.index_count = len(indices)
	return mesh, true
}

r3d_webgl_destroy_mesh :: proc(s: ^R3d_WebGL_State, mesh: R3d_Backend_Mesh) {
	gl.DeleteBuffer(gl.Buffer(u32(uintptr(mesh.vertex_buffer))))
	gl.DeleteBuffer(gl.Buffer(u32(uintptr(mesh.index_buffer))))
	gl.DeleteVertexArray(gl.VertexArrayObject(mesh.vertex_array))
}

r3d_webgl_upload_lights :: proc(s: ^R3d_WebGL_State, textures: ^R3d_Light_Textures) {
	sources := [3]^R3d_Data_Texture{&textures.lights, &textures.grid, &textures.indices}
	gl.ActiveTexture(gl.TEXTURE3)

	for source, i in sources {
		gl.BindTexture(gl.TEXTURE_2D, s.light_textures[i])
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, R3D_DATA_TEXTURE_WIDTH, R3D_DATA_TEXTURE_HEIGHT, gl.RGBA, gl.FLOAT, size_of(R3d_Data_Texture), &source[0])
	}

	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.ActiveTexture(gl.TEXTURE0)
}

r3d_webgl_begin_pass :: proc(s: ^R3d_WebGL_State, target: Render_Target_Handle, width, height: int, flip_y: bool, globals: ^R3d_Globals) {
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
	gl.BindSampler(gl.Enum(0), s.sampler_point)
	gl.BindSampler(gl.Enum(1), s.sampler_linear)
	gl.BindSampler(gl.Enum(2), s.sampler_linear)

	for i in 0 ..< 3 {
		gl.ActiveTexture(gl.Enum(u32(gl.TEXTURE3) + u32(i)))
		gl.BindTexture(gl.TEXTURE_2D, s.light_textures[i])
		gl.BindSampler(gl.Enum(3 + i), s.sampler_point)
	}

	gl.ActiveTexture(gl.TEXTURE0)
}

r3d_webgl_end_pass :: proc(s: ^R3d_WebGL_State) {
	for unit in 0 ..< 6 {
		gl.ActiveTexture(gl.Enum(u32(gl.TEXTURE0) + u32(unit)))
		gl.BindTexture(gl.TEXTURE_2D, 0)
		gl.BindSampler(gl.Enum(unit), 0)
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

r3d_webgl_native_texture :: proc(s: ^R3d_WebGL_State, texture: Render_Backend_Texture) -> gl.Texture {
	if tex := hm.get(&s.rb.textures, texture); tex != nil {
		return tex.id
	}

	return s.white_texture
}

r3d_webgl_draw :: proc(
	s: ^R3d_WebGL_State,
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
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, R3D_INSTANCE_ROW_TEXELS, i32(full_rows), gl.RGBA, gl.FLOAT, full_rows * R3D_INSTANCES_PER_ROW * size_of(R3d_Instance), raw_data(instances))
	}

	if rest > 0 {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, i32(full_rows), i32(rest * R3D_INSTANCE_TEXELS), 1, gl.RGBA, gl.FLOAT, rest * size_of(R3d_Instance), &instances[full_rows * R3D_INSTANCES_PER_ROW])
	}

	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, r3d_webgl_native_texture(s, albedo))
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, r3d_webgl_native_texture(s, ramp))
	gl.ActiveTexture(gl.TEXTURE0)

	cull_back := pass == .Main
	if s.flip_y {
		cull_back = !cull_back
	}
	gl.CullFace(gl.BACK if cull_back else gl.FRONT)

	gl.UseProgram(s.programs[pass])
	gl.BindVertexArray(gl.VertexArrayObject(mesh.vertex_array))
	gl.DrawElementsInstanced(gl.TRIANGLES, mesh.index_count, gl.UNSIGNED_INT, 0, count)
}

r3d_webgl_read_pixels :: proc(s: ^R3d_WebGL_State, target: Render_Target_Handle, width, height: int, out_rgba8: []u8) -> bool {
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)

	if rt := hm.get(&s.rb.render_targets, target); rt != nil {
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.framebuffer)
		pixels := make([]f32, width * height * 4, context.temp_allocator)
		gl.ReadPixelsSlice(0, 0, i32(width), i32(height), gl.RGBA, gl.FLOAT, pixels)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

		for i in 0 ..< width * height * 4 {
			out_rgba8[i] = u8(math.round(clamp(pixels[i], 0, 1) * 255))
		}

		return true
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	gl.ReadPixelsSlice(0, 0, i32(width), i32(height), gl.RGBA, gl.UNSIGNED_BYTE, pixels)

	for y in 0 ..< height {
		source := pixels[(height - 1 - y) * width * 4:][:width * 4]
		copy(out_rgba8[y * width * 4:][:width * 4], source)
	}

	return true
}
