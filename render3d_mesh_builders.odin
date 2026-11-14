// RENDER3D: procedural meshes for the 3D layer (counter clockwise front faces, Y up). The outline normal is the averaged normal of coincident vertices, so hard edges keep a closed outline.
package karl2d

import "core:math"
import "core:math/linalg"

R3d_Mesh_Data :: struct {
	vertices: [dynamic]R3d_Vertex,
	indices: [dynamic]u32,
}

r3d_mesh_data_destroy :: proc(data: ^R3d_Mesh_Data) {
	delete(data.vertices)
	delete(data.indices)
	data^ = {}
}

@(private="file")
pack_snorm :: proc(n: Vec3) -> [4]i8 {
	return {i8(math.round(n.x * 127)), i8(math.round(n.y * 127)), i8(math.round(n.z * 127)), 0}
}

r3d_mesh_data_smooth_outline_normals :: proc(data: ^R3d_Mesh_Data) {
	Key :: [3]i32
	sums := make(map[Key]Vec3, allocator = context.temp_allocator)
	key_of :: proc(p: Vec3) -> Key {
		return {i32(math.round(p.x * 1000)), i32(math.round(p.y * 1000)), i32(math.round(p.z * 1000))}
	}
	for v in data.vertices {
		k := key_of(v.position)
		sums[k] = sums[k] + v.normal
	}
	for &v in data.vertices {
		n := sums[key_of(v.position)]
		if linalg.length2(n) > 1e-8 {
			v.outline_normal = pack_snorm(linalg.normalize(n))
		} else {
			v.outline_normal = pack_snorm(v.normal)
		}
	}
}

r3d_mesh_data_add_quad :: proc(data: ^R3d_Mesh_Data, a, b, c, d: Vec3, normal: Vec3, color: Color = {255, 255, 255, 255}) {
	base := u32(len(data.vertices))
	append(&data.vertices,
		R3d_Vertex{position = a, normal = normal, uv = {0, 1}, color = color},
		R3d_Vertex{position = b, normal = normal, uv = {1, 1}, color = color},
		R3d_Vertex{position = c, normal = normal, uv = {1, 0}, color = color},
		R3d_Vertex{position = d, normal = normal, uv = {0, 0}, color = color},
	)
	append(&data.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

r3d_mesh_data_cube :: proc(size: Vec3 = {1, 1, 1}, color: Color = {255, 255, 255, 255}) -> R3d_Mesh_Data {
	h := size * 0.5
	data: R3d_Mesh_Data
	r3d_mesh_data_add_quad(&data, {-h.x, -h.y, h.z}, {h.x, -h.y, h.z}, {h.x, h.y, h.z}, {-h.x, h.y, h.z}, {0, 0, 1}, color)
	r3d_mesh_data_add_quad(&data, {h.x, -h.y, -h.z}, {-h.x, -h.y, -h.z}, {-h.x, h.y, -h.z}, {h.x, h.y, -h.z}, {0, 0, -1}, color)
	r3d_mesh_data_add_quad(&data, {h.x, -h.y, h.z}, {h.x, -h.y, -h.z}, {h.x, h.y, -h.z}, {h.x, h.y, h.z}, {1, 0, 0}, color)
	r3d_mesh_data_add_quad(&data, {-h.x, -h.y, -h.z}, {-h.x, -h.y, h.z}, {-h.x, h.y, h.z}, {-h.x, h.y, -h.z}, {-1, 0, 0}, color)
	r3d_mesh_data_add_quad(&data, {-h.x, h.y, h.z}, {h.x, h.y, h.z}, {h.x, h.y, -h.z}, {-h.x, h.y, -h.z}, {0, 1, 0}, color)
	r3d_mesh_data_add_quad(&data, {-h.x, -h.y, -h.z}, {h.x, -h.y, -h.z}, {h.x, -h.y, h.z}, {-h.x, -h.y, h.z}, {0, -1, 0}, color)
	r3d_mesh_data_smooth_outline_normals(&data)
	return data
}

r3d_mesh_data_plane :: proc(size: Vec2 = {10, 10}, color: Color = {255, 255, 255, 255}) -> R3d_Mesh_Data {
	h := size * 0.5
	data: R3d_Mesh_Data
	r3d_mesh_data_add_quad(&data, {-h.x, 0, h.y}, {h.x, 0, h.y}, {h.x, 0, -h.y}, {-h.x, 0, -h.y}, {0, 1, 0}, color)
	r3d_mesh_data_smooth_outline_normals(&data)
	return data
}

r3d_mesh_data_sphere :: proc(radius: f32 = 0.5, rings: int = 16, segments: int = 24, color: Color = {255, 255, 255, 255}) -> R3d_Mesh_Data {
	data: R3d_Mesh_Data
	for r in 0 ..= rings {
		v := f32(r) / f32(rings)
		phi := v * math.PI
		for sg in 0 ..= segments {
			u := f32(sg) / f32(segments)
			theta := u * 2 * math.PI
			n := Vec3{math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)}
			append(&data.vertices, R3d_Vertex{position = n * radius, normal = n, uv = {u, v}, color = color, outline_normal = pack_snorm(n)})
		}
	}
	stride := u32(segments + 1)
	for r in 0 ..< rings {
		for sg in 0 ..< segments {
			i0 := u32(r) * stride + u32(sg)
			i1 := i0 + 1
			i2 := i0 + stride
			i3 := i2 + 1
			append(&data.indices, i0, i1, i2, i1, i3, i2)
		}
	}
	return data
}

r3d_mesh_data_cylinder :: proc(radius: f32 = 0.5, height: f32 = 1, segments: int = 24, color: Color = {255, 255, 255, 255}) -> R3d_Mesh_Data {
	data: R3d_Mesh_Data
	h := height * 0.5
	for sg in 0 ..= segments {
		u := f32(sg) / f32(segments)
		theta := u * 2 * math.PI
		n := Vec3{math.cos(theta), 0, math.sin(theta)}
		append(&data.vertices,
			R3d_Vertex{position = {n.x * radius, -h, n.z * radius}, normal = n, uv = {u, 1}, color = color, outline_normal = pack_snorm(n)},
			R3d_Vertex{position = {n.x * radius, h, n.z * radius}, normal = n, uv = {u, 0}, color = color, outline_normal = pack_snorm(n)},
		)
	}
	for sg in 0 ..< segments {
		i := u32(sg) * 2
		append(&data.indices, i, i + 1, i + 2, i + 1, i + 3, i + 2)
	}
	for cap in 0 ..< 2 {
		y := h if cap == 1 else -h
		n := Vec3{0, 1 if cap == 1 else -1, 0}
		center := u32(len(data.vertices))
		append(&data.vertices, R3d_Vertex{position = {0, y, 0}, normal = n, uv = {0.5, 0.5}, color = color, outline_normal = pack_snorm(n)})
		for sg in 0 ..= segments {
			theta := f32(sg) / f32(segments) * 2 * math.PI
			append(&data.vertices, R3d_Vertex{position = {math.cos(theta) * radius, y, math.sin(theta) * radius}, normal = n, uv = {0.5 + 0.5 * math.cos(theta), 0.5 + 0.5 * math.sin(theta)}, color = color, outline_normal = pack_snorm(n)})
		}
		for sg in 0 ..< segments {
			a := center + 1 + u32(sg)
			if cap == 1 {
				append(&data.indices, center, a + 1, a)
			} else {
				append(&data.indices, center, a, a + 1)
			}
		}
	}
	return data
}
