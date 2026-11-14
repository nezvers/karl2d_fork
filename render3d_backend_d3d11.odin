// RENDER3D: 3D backend for D3D11. Owns its shaders, buffers and pipeline states. Uses the device, render targets and textures of the karl2d D3D11 backend. Textures are bound to the vertex stage here, which the 2D backend never does.
#+build windows
#+private package
package karl2d

import d3d11 "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "base:runtime"
import "core:log"
import "core:math"
import "core:strings"
import hm "core:container/handle_map"

R3D_BACKEND_D3D11 :: R3d_Backend_Interface {
	state_type = R3d_D3D11_State,
	init = r3d_d3d11_init,
	shutdown = r3d_d3d11_shutdown,
	create_mesh = r3d_d3d11_create_mesh,
	upload_lights = r3d_d3d11_upload_lights,
	destroy_mesh = r3d_d3d11_destroy_mesh,
	begin_pass = r3d_d3d11_begin_pass,
	end_pass = r3d_d3d11_end_pass,
	draw = r3d_d3d11_draw,
	read_pixels = r3d_d3d11_read_pixels,
}

R3D_MESH_SHADER_D3D11 :: #load("render3d_shaders/r3d_mesh_d3d11.hlsl")

R3d_D3D11_State :: struct {
	using _: R3d_Backend_State,
	rb: ^D3D11_State,
	allocator: runtime.Allocator,
	max_instances: int,

	vertex_shaders: [R3d_Pass]^d3d11.IVertexShader,
	pixel_shaders: [R3d_Pass]^d3d11.IPixelShader,
	input_layout: ^d3d11.IInputLayout,
	rasterizers: [2]^d3d11.IRasterizerState,
	depth_state: ^d3d11.IDepthStencilState,
	globals_buffer: ^d3d11.IBuffer,
	material_buffer: ^d3d11.IBuffer,
	instance_texture: ^d3d11.ITexture2D,
	instance_view: ^d3d11.IShaderResourceView,
	sampler_point: ^d3d11.ISamplerState,
	sampler_linear: ^d3d11.ISamplerState,
	white_texture: ^d3d11.ITexture2D,
	white_view: ^d3d11.IShaderResourceView,
	light_textures: [3]^d3d11.ITexture2D,
	light_views: [3]^d3d11.IShaderResourceView,

	flip_y: bool,
}

r3d_d3d11_compile :: proc(source: []byte, entry: cstring, target: cstring) -> ^d3d11.IBlob {
	blob: ^d3d11.IBlob
	errors: ^d3d11.IBlob
	hr := d3d_compiler.Compile(raw_data(source), len(source), nil, nil, nil, entry, target, 0, 0, &blob, &errors)

	if errors != nil {
		log.errorf("3D shader %v failed:\n%v", entry, strings.string_from_ptr((^u8)(errors->GetBufferPointer()), int(errors->GetBufferSize())))
		errors->Release()
	}

	if hr < 0 || blob == nil {
		return nil
	}

	return blob
}

r3d_d3d11_init :: proc(s: ^R3d_D3D11_State, rb_state: ^Render_Backend_State, max_instances: int, allocator: runtime.Allocator) -> bool {
	s.rb = (^D3D11_State)(rb_state)
	s.allocator = allocator
	s.max_instances = max_instances
	device := s.rb.device

	passes := [R3d_Pass]struct{ vs: cstring, ps: cstring} {
		.Main = {"vs_main", "ps_main"},
		.Outline = {"vs_outline", "ps_outline"},
	}

	layout_blob: ^d3d11.IBlob

	for pass in R3d_Pass {
		vs_blob := r3d_d3d11_compile(R3D_MESH_SHADER_D3D11, passes[pass].vs, "vs_5_0")
		ps_blob := r3d_d3d11_compile(R3D_MESH_SHADER_D3D11, passes[pass].ps, "ps_5_0")

		if vs_blob == nil || ps_blob == nil {
			return false
		}

		if !d3d11_check(s.rb, device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &s.vertex_shaders[pass])) {
			return false
		}

		if !d3d11_check(s.rb, device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &s.pixel_shaders[pass])) {
			return false
		}

		ps_blob->Release()

		if pass == .Main {
			layout_blob = vs_blob
		} else {
			vs_blob->Release()
		}
	}

	elements := [?]d3d11.INPUT_ELEMENT_DESC {
		{SemanticName = "POSITION", Format = .R32G32B32_FLOAT, AlignedByteOffset = 0, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "NORMAL", Format = .R32G32B32_FLOAT, AlignedByteOffset = 12, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "TEXCOORD", SemanticIndex = 0, Format = .R32G32_FLOAT, AlignedByteOffset = 24, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "COLOR", Format = .R8G8B8A8_UNORM, AlignedByteOffset = 32, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "BLENDINDICES", Format = .R8G8B8A8_UINT, AlignedByteOffset = 36, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "BLENDWEIGHT", Format = .R8G8B8A8_UNORM, AlignedByteOffset = 40, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "TEXCOORD", SemanticIndex = 1, Format = .R8G8B8A8_SNORM, AlignedByteOffset = 44, InputSlotClass = .VERTEX_DATA},
	}

	ok := d3d11_check(s.rb, device->CreateInputLayout(&elements[0], len(elements), layout_blob->GetBufferPointer(), layout_blob->GetBufferSize(), &s.input_layout))
	layout_blob->Release()

	if !ok {
		return false
	}

	for cull, i in ([2]d3d11.CULL_MODE{.BACK, .FRONT}) {
		desc := d3d11.RASTERIZER_DESC {
			FillMode = .SOLID,
			CullMode = cull,
			FrontCounterClockwise = true,
			DepthClipEnable = true,
			MultisampleEnable = d3d11.BOOL(s.rb.anti_alias),
		}

		if !d3d11_check(s.rb, device->CreateRasterizerState(&desc, &s.rasterizers[i])) {
			return false
		}
	}

	depth_desc := d3d11.DEPTH_STENCIL_DESC {
		DepthEnable = true,
		DepthWriteMask = .ALL,
		DepthFunc = .GREATER_EQUAL,
	}

	if !d3d11_check(s.rb, device->CreateDepthStencilState(&depth_desc, &s.depth_state)) {
		return false
	}

	globals_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(size_of(R3d_Globals)),
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}

	if !d3d11_check(s.rb, device->CreateBuffer(&globals_desc, nil, &s.globals_buffer)) {
		return false
	}

	material_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(size_of(R3d_Material_Constants)),
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}

	if !d3d11_check(s.rb, device->CreateBuffer(&material_desc, nil, &s.material_buffer)) {
		return false
	}

	rows := (max_instances + R3D_INSTANCES_PER_ROW - 1) / R3D_INSTANCES_PER_ROW
	instance_desc := d3d11.TEXTURE2D_DESC {
		Width = R3D_INSTANCE_ROW_TEXELS,
		Height = u32(rows),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R32G32B32A32_FLOAT,
		SampleDesc = {Count = 1},
		Usage = .DYNAMIC,
		BindFlags = {.SHADER_RESOURCE},
		CPUAccessFlags = {.WRITE},
	}

	if !d3d11_check(s.rb, device->CreateTexture2D(&instance_desc, nil, &s.instance_texture)) {
		return false
	}

	if !d3d11_check(s.rb, device->CreateShaderResourceView(s.instance_texture, nil, &s.instance_view)) {
		return false
	}

	white_pixel := [4]u8{255, 255, 255, 255}
	white_desc := d3d11.TEXTURE2D_DESC {
		Width = 1,
		Height = 1,
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
	}
	white_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = &white_pixel[0],
		SysMemPitch = 4,
	}

	if !d3d11_check(s.rb, device->CreateTexture2D(&white_desc, &white_data, &s.white_texture)) {
		return false
	}

	if !d3d11_check(s.rb, device->CreateShaderResourceView(s.white_texture, nil, &s.white_view)) {
		return false
	}

	light_desc := d3d11.TEXTURE2D_DESC {
		Width = R3D_DATA_TEXTURE_WIDTH,
		Height = R3D_DATA_TEXTURE_HEIGHT,
		MipLevels = 1,
		ArraySize = 1,
		Format = .R32G32B32A32_FLOAT,
		SampleDesc = {Count = 1},
		Usage = .DYNAMIC,
		BindFlags = {.SHADER_RESOURCE},
		CPUAccessFlags = {.WRITE},
	}

	for i in 0 ..< 3 {
		if !d3d11_check(s.rb, device->CreateTexture2D(&light_desc, nil, &s.light_textures[i])) {
			return false
		}

		if !d3d11_check(s.rb, device->CreateShaderResourceView(s.light_textures[i], nil, &s.light_views[i])) {
			return false
		}
	}

	point_desc := d3d11.SAMPLER_DESC {
		Filter = .MIN_MAG_MIP_POINT,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		ComparisonFunc = .NEVER,
		MaxLOD = d3d11.FLOAT32_MAX,
	}

	if !d3d11_check(s.rb, device->CreateSamplerState(&point_desc, &s.sampler_point)) {
		return false
	}

	linear_desc := point_desc
	linear_desc.Filter = .MIN_MAG_MIP_LINEAR
	linear_desc.AddressU = .WRAP
	linear_desc.AddressV = .WRAP

	return d3d11_check(s.rb, device->CreateSamplerState(&linear_desc, &s.sampler_linear))
}

r3d_d3d11_shutdown :: proc(s: ^R3d_D3D11_State) {
	for pass in R3d_Pass {
		if s.vertex_shaders[pass] != nil { s.vertex_shaders[pass]->Release() }
		if s.pixel_shaders[pass] != nil { s.pixel_shaders[pass]->Release() }
	}

	for rasterizer in s.rasterizers {
		if rasterizer != nil { rasterizer->Release() }
	}

	if s.input_layout != nil { s.input_layout->Release() }
	if s.depth_state != nil { s.depth_state->Release() }
	if s.globals_buffer != nil { s.globals_buffer->Release() }
	if s.material_buffer != nil { s.material_buffer->Release() }
	if s.instance_view != nil { s.instance_view->Release() }
	if s.instance_texture != nil { s.instance_texture->Release() }
	for i in 0 ..< 3 {
		if s.light_views[i] != nil { s.light_views[i]->Release() }
		if s.light_textures[i] != nil { s.light_textures[i]->Release() }
	}

	if s.white_view != nil { s.white_view->Release() }
	if s.white_texture != nil { s.white_texture->Release() }
	if s.sampler_point != nil { s.sampler_point->Release() }
	if s.sampler_linear != nil { s.sampler_linear->Release() }
}

r3d_d3d11_create_mesh :: proc(s: ^R3d_D3D11_State, vertices: []R3d_Vertex, indices: []u32) -> (R3d_Backend_Mesh, bool) {
	vertex_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertices) * size_of(R3d_Vertex)),
		Usage = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vertex_data := d3d11.SUBRESOURCE_DATA {pSysMem = raw_data(vertices)}
	vertex_buffer: ^d3d11.IBuffer

	if !d3d11_check(s.rb, s.rb.device->CreateBuffer(&vertex_desc, &vertex_data, &vertex_buffer)) {
		return {}, false
	}

	index_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(indices) * size_of(u32)),
		Usage = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	index_data := d3d11.SUBRESOURCE_DATA {pSysMem = raw_data(indices)}
	index_buffer: ^d3d11.IBuffer

	if !d3d11_check(s.rb, s.rb.device->CreateBuffer(&index_desc, &index_data, &index_buffer)) {
		vertex_buffer->Release()
		return {}, false
	}

	return {
		vertex_buffer = vertex_buffer,
		index_buffer = index_buffer,
		vertex_count = len(vertices),
		index_count = len(indices),
	}, true
}

r3d_d3d11_destroy_mesh :: proc(s: ^R3d_D3D11_State, mesh: R3d_Backend_Mesh) {
	(^d3d11.IBuffer)(mesh.vertex_buffer)->Release()
	(^d3d11.IBuffer)(mesh.index_buffer)->Release()
}

r3d_d3d11_upload :: proc(s: ^R3d_D3D11_State, buffer: ^d3d11.IBuffer, data: rawptr, size: int) {
	mapped: d3d11.MAPPED_SUBRESOURCE

	if d3d11_check(s.rb, s.rb.device_context->Map(buffer, 0, .WRITE_DISCARD, {}, &mapped)) {
		runtime.mem_copy(mapped.pData, data, size)
		s.rb.device_context->Unmap(buffer, 0)
	}
}

r3d_d3d11_upload_lights :: proc(s: ^R3d_D3D11_State, textures: ^R3d_Light_Textures) {
	dc := s.rb.device_context
	sources := [3]^R3d_Data_Texture{&textures.lights, &textures.grid, &textures.indices}

	for source, i in sources {
		mapped: d3d11.MAPPED_SUBRESOURCE

		if !d3d11_check(s.rb, dc->Map(s.light_textures[i], 0, .WRITE_DISCARD, {}, &mapped)) {
			continue
		}

		row_bytes := R3D_DATA_TEXTURE_WIDTH * size_of([4]f32)

		for row in 0 ..< R3D_DATA_TEXTURE_HEIGHT {
			dst := rawptr(uintptr(mapped.pData) + uintptr(row) * uintptr(mapped.RowPitch))
			runtime.mem_copy(dst, &source[row * R3D_DATA_TEXTURE_WIDTH], row_bytes)
		}

		dc->Unmap(s.light_textures[i], 0)
	}
}

r3d_d3d11_begin_pass :: proc(s: ^R3d_D3D11_State, target: Render_Target_Handle, width, height: int, flip_y: bool, globals: ^R3d_Globals) {
	dc := s.rb.device_context
	s.flip_y = flip_y

	rtv := s.rb.framebuffer_view
	dsv := s.rb.depth_buffer_view
	w, h := s.rb.width, s.rb.height

	if rt := hm.get(&s.rb.render_targets, target); rt != nil {
		rtv, dsv = rt.render_target_view, rt.depth_buffer_view
		w, h = rt.width, rt.height
	}

	dc->OMSetRenderTargets(1, &rtv, dsv)

	viewport := d3d11.VIEWPORT {0, 0, f32(w), f32(h), 0, 1}
	dc->RSSetViewports(1, &viewport)
	dc->IASetPrimitiveTopology(.TRIANGLELIST)
	dc->IASetInputLayout(s.input_layout)
	dc->OMSetDepthStencilState(s.depth_state, 0)
	dc->OMSetBlendState(nil, nil, ~u32(0))

	r3d_d3d11_upload(s, s.globals_buffer, globals, size_of(R3d_Globals))

	dc->VSSetConstantBuffers(0, 1, &s.globals_buffer)
	dc->PSSetConstantBuffers(0, 1, &s.globals_buffer)
	dc->VSSetConstantBuffers(1, 1, &s.material_buffer)
	dc->PSSetConstantBuffers(1, 1, &s.material_buffer)
	dc->VSSetShaderResources(0, 1, &s.instance_view)
	dc->PSSetShaderResources(3, 3, &s.light_views[0])
	dc->VSSetSamplers(0, 1, &s.sampler_point)
	dc->PSSetSamplers(1, 1, &s.sampler_linear)
}

r3d_d3d11_end_pass :: proc(s: ^R3d_D3D11_State) {
	dc := s.rb.device_context
	no_views := [5]^d3d11.IShaderResourceView{}
	dc->VSSetShaderResources(0, 1, &no_views[0])
	dc->PSSetShaderResources(1, 5, &no_views[0])
	dc->OMSetRenderTargets(0, nil, nil)
	d3d11_log_messages(s.rb)
}

r3d_d3d11_native_view :: proc(s: ^R3d_D3D11_State, texture: Render_Backend_Texture) -> ^d3d11.IShaderResourceView {
	if tex := hm.get(&s.rb.textures, texture); tex != nil {
		return tex.view
	}

	return s.white_view
}

r3d_d3d11_draw :: proc(
	s: ^R3d_D3D11_State,
	mesh: R3d_Backend_Mesh,
	pass: R3d_Pass,
	material: ^R3d_Material_Constants,
	albedo: Render_Backend_Texture,
	ramp: Render_Backend_Texture,
	instances: []R3d_Instance,
) {
	dc := s.rb.device_context
	count := min(len(instances), s.max_instances)

	r3d_d3d11_upload(s, s.material_buffer, material, size_of(R3d_Material_Constants))

	mapped: d3d11.MAPPED_SUBRESOURCE

	if !d3d11_check(s.rb, dc->Map(s.instance_texture, 0, .WRITE_DISCARD, {}, &mapped)) {
		return
	}

	row_bytes := R3D_INSTANCES_PER_ROW * size_of(R3d_Instance)
	remaining := count
	row := 0

	for remaining > 0 {
		in_row := min(remaining, R3D_INSTANCES_PER_ROW)
		dst := rawptr(uintptr(mapped.pData) + uintptr(row) * uintptr(mapped.RowPitch))
		src := rawptr(&instances[row * R3D_INSTANCES_PER_ROW])
		runtime.mem_copy(dst, src, in_row * size_of(R3d_Instance))
		remaining -= in_row
		row += 1
	}

	_ = row_bytes
	dc->Unmap(s.instance_texture, 0)

	views := [2]^d3d11.IShaderResourceView {
		r3d_d3d11_native_view(s, albedo),
		r3d_d3d11_native_view(s, ramp),
	}
	dc->PSSetShaderResources(1, 2, &views[0])

	rasterizer_index := 0 if pass == .Main else 1

	if s.flip_y {
		rasterizer_index = 1 - rasterizer_index
	}

	dc->RSSetState(s.rasterizers[rasterizer_index])
	dc->VSSetShader(s.vertex_shaders[pass], nil, 0)
	dc->PSSetShader(s.pixel_shaders[pass], nil, 0)

	stride := u32(size_of(R3d_Vertex))
	offset: u32
	vertex_buffer := (^d3d11.IBuffer)(mesh.vertex_buffer)
	dc->IASetVertexBuffers(0, 1, &vertex_buffer, &stride, &offset)
	dc->IASetIndexBuffer((^d3d11.IBuffer)(mesh.index_buffer), .R32_UINT, 0)
	dc->DrawIndexedInstanced(u32(mesh.index_count), u32(count), 0, 0, 0)
}

r3d_d3d11_read_pixels :: proc(s: ^R3d_D3D11_State, target: Render_Target_Handle, width, height: int, out_rgba8: []u8) -> bool {
	dc := s.rb.device_context
	source: ^d3d11.ITexture2D

	if rt := hm.get(&s.rb.render_targets, target); rt != nil {
		resource: ^d3d11.IResource
		rt.render_target_view->GetResource(&resource)
		source = (^d3d11.ITexture2D)(resource)
	} else {
		source = s.rb.framebuffer
		source->AddRef()
	}

	defer source->Release()

	desc: d3d11.TEXTURE2D_DESC
	source->GetDesc(&desc)

	if desc.SampleDesc.Count > 1 {
		log.error("r3d_read_pixels does not resolve multisampled targets")
		return false
	}

	desc.Usage = .STAGING
	desc.BindFlags = {}
	desc.CPUAccessFlags = {.READ}
	desc.MiscFlags = {}
	staging: ^d3d11.ITexture2D

	if !d3d11_check(s.rb, s.rb.device->CreateTexture2D(&desc, nil, &staging)) {
		return false
	}

	defer staging->Release()

	dc->CopyResource(staging, source)
	mapped: d3d11.MAPPED_SUBRESOURCE

	if !d3d11_check(s.rb, dc->Map(staging, 0, .READ, {}, &mapped)) {
		return false
	}

	defer dc->Unmap(staging, 0)

	for y in 0 ..< min(height, int(desc.Height)) {
		row := rawptr(uintptr(mapped.pData) + uintptr(y) * uintptr(mapped.RowPitch))

		for x in 0 ..< min(width, int(desc.Width)) {
			out := out_rgba8[(y * width + x) * 4:][:4]

			#partial switch desc.Format {
			case .R32G32B32A32_FLOAT:
				pixel := ([^][4]f32)(row)[x]
				for c in 0 ..< 4 {
					out[c] = u8(math.round(clamp(pixel[c], 0, 1) * 255))
				}
			case .B8G8R8A8_UNORM:
				pixel := ([^][4]u8)(row)[x]
				out[0], out[1], out[2], out[3] = pixel[2], pixel[1], pixel[0], pixel[3]
			case .R8G8B8A8_UNORM:
				pixel := ([^][4]u8)(row)[x]
				out[0], out[1], out[2], out[3] = pixel[0], pixel[1], pixel[2], pixel[3]
			case:
				log.errorf("r3d_read_pixels: unsupported format %v", desc.Format)
				return false
			}
		}
	}

	return true
}
