// RENDER3D: clustered lights. The view volume is cut into a grid of clusters (tiles in x/y, logarithmic slices in depth). Every frame the CPU lists, per cluster, the lights that can reach it, and writes three float data textures: the lights, the per cluster (offset, count) and the packed light indices. The pixel shader finds its cluster from the screen position and the view depth and loops over only the lights of that cluster, so hundreds of lights cost what the visible few cost.
package karl2d

import "core:math"
import "core:math/linalg"

R3D_CLUSTERS_X :: 16
R3D_CLUSTERS_Y :: 9
R3D_CLUSTERS_Z :: 24
R3D_CLUSTER_COUNT :: R3D_CLUSTERS_X * R3D_CLUSTERS_Y * R3D_CLUSTERS_Z
R3D_MAX_LIGHTS :: 1024
R3D_MAX_LIGHTS_PER_CLUSTER :: 96
R3D_DATA_TEXTURE_WIDTH :: 1024
R3D_DATA_TEXTURE_HEIGHT :: 4
R3D_DATA_TEXELS :: R3D_DATA_TEXTURE_WIDTH * R3D_DATA_TEXTURE_HEIGHT
R3D_MAX_INDEX_ENTRIES :: R3D_DATA_TEXELS * 4

#assert(R3D_CLUSTER_COUNT <= R3D_DATA_TEXELS)
#assert(R3D_MAX_LIGHTS * 3 <= R3D_DATA_TEXELS)

R3d_Data_Texture :: [R3D_DATA_TEXELS][4]f32

R3d_Light :: struct {
	position: Vec3,
	radius: f32,
	color: Vec3,
	intensity: f32,
	direction: Vec3,
	spot_outer_degrees: f32,
	spot_inner_degrees: f32,
}

R3d_Light_Stats :: struct {
	lights: int,
	culled: int,
	entries: int,
	dropped_entries: int,
	busiest_cluster: int,
}

R3d_Cluster_Params :: struct {
	near: f32,
	far: f32,
	scale: f32,
	bias: f32,
}

R3d_Light_Textures :: struct {
	lights: R3d_Data_Texture,
	grid: R3d_Data_Texture,
	indices: R3d_Data_Texture,
}

r3d_cluster_params :: proc(near, far: f32) -> R3d_Cluster_Params {
	n := max(near, 0.001)
	f := max(far, n * 2)
	scale := f32(R3D_CLUSTERS_Z) / math.ln(f / n)
	return {near = n, far = f, scale = scale, bias = -math.ln(n) * scale}
}

r3d_cluster_slice :: proc(params: R3d_Cluster_Params, view_depth: f32) -> int {
	slice := int(math.ln(max(view_depth, params.near)) * params.scale + params.bias)
	return clamp(slice, 0, R3D_CLUSTERS_Z - 1)
}

r3d_cluster_tile :: proc(ndc: f32, count: int) -> int {
	return clamp(int((ndc * 0.5 + 0.5) * f32(count)), 0, count - 1)
}

r3d_cluster_index :: proc(x, y, z: int) -> int {
	return (z * R3D_CLUSTERS_Y + y) * R3D_CLUSTERS_X + x
}

r3d_cluster_of_point :: proc(view: Mat4, view_projection: Mat4, params: R3d_Cluster_Params, world: Vec3) -> (index: int, in_view: bool) {
	v := view * [4]f32{world.x, world.y, world.z, 1}
	depth := -v.z
	clip := view_projection * [4]f32{world.x, world.y, world.z, 1}

	if clip.w <= 1e-6 {
		return 0, false
	}

	ndc := clip.xy / clip.w
	x := r3d_cluster_tile(ndc.x, R3D_CLUSTERS_X)
	y := r3d_cluster_tile(ndc.y, R3D_CLUSTERS_Y)
	z := r3d_cluster_slice(params, depth)
	return r3d_cluster_index(x, y, z), abs(ndc.x) <= 1 && abs(ndc.y) <= 1 && depth > 0
}

r3d_pack_lights :: proc(textures: ^R3d_Light_Textures, lights: []R3d_Light) -> int {
	count := min(len(lights), R3D_MAX_LIGHTS)

	for i in 0 ..< count {
		light := lights[i]
		direction := light.direction
		has_direction := linalg.length2(direction) > 1e-8

		if has_direction {
			direction = linalg.normalize(direction)
		}

		outer := math.cos(math.to_radians(light.spot_outer_degrees)) if light.spot_outer_degrees > 0 else -2
		inner := math.cos(math.to_radians(light.spot_inner_degrees)) if light.spot_inner_degrees > 0 else outer
		scaled := light.color * light.intensity

		textures.lights[i * 3 + 0] = {light.position.x, light.position.y, light.position.z, max(light.radius, 0.001)}
		textures.lights[i * 3 + 1] = {scaled.x, scaled.y, scaled.z, outer}
		textures.lights[i * 3 + 2] = {direction.x, direction.y, direction.z, inner}
	}

	return count
}

r3d_bin_lights :: proc(
	textures: ^R3d_Light_Textures,
	lights: []R3d_Light,
	view: Mat4,
	view_projection: Mat4,
	params: R3d_Cluster_Params,
	allocator := context.temp_allocator,
) -> R3d_Light_Stats {
	stats: R3d_Light_Stats
	stats.lights = r3d_pack_lights(textures, lights)

	lists := make([][R3D_MAX_LIGHTS_PER_CLUSTER]u16, R3D_CLUSTER_COUNT, allocator)
	counts := make([]int, R3D_CLUSTER_COUNT, allocator)

	for i in 0 ..< stats.lights {
		light := lights[i]
		radius := max(light.radius, 0.001)
		v := view * [4]f32{light.position.x, light.position.y, light.position.z, 1}
		depth := -v.z

		if depth + radius < params.near {
			stats.culled += 1
			continue
		}

		z0 := r3d_cluster_slice(params, depth - radius)
		z1 := r3d_cluster_slice(params, depth + radius)
		x0, x1 := 0, R3D_CLUSTERS_X - 1
		y0, y1 := 0, R3D_CLUSTERS_Y - 1

		reaches_camera_plane := depth - radius <= params.near
		min_ndc := [2]f32{math.F32_MAX, math.F32_MAX}
		max_ndc := [2]f32{-math.F32_MAX, -math.F32_MAX}

		if !reaches_camera_plane {
			for corner in 0 ..< 8 {
				offset := Vec3{
					radius if corner & 1 != 0 else -radius,
					radius if corner & 2 != 0 else -radius,
					radius if corner & 4 != 0 else -radius,
				}
				p := light.position + offset
				clip := view_projection * [4]f32{p.x, p.y, p.z, 1}

				if clip.w <= 1e-4 {
					reaches_camera_plane = true
					break
				}

				ndc := clip.xy / clip.w
				min_ndc = {min(min_ndc.x, ndc.x), min(min_ndc.y, ndc.y)}
				max_ndc = {max(max_ndc.x, ndc.x), max(max_ndc.y, ndc.y)}
			}
		}

		if !reaches_camera_plane {
			if max_ndc.x < -1 || min_ndc.x > 1 || max_ndc.y < -1 || min_ndc.y > 1 {
				stats.culled += 1
				continue
			}

			x0, x1 = r3d_cluster_tile(min_ndc.x, R3D_CLUSTERS_X), r3d_cluster_tile(max_ndc.x, R3D_CLUSTERS_X)
			y0, y1 = r3d_cluster_tile(min_ndc.y, R3D_CLUSTERS_Y), r3d_cluster_tile(max_ndc.y, R3D_CLUSTERS_Y)
		}

		for z in z0 ..= z1 {
			for y in y0 ..= y1 {
				for x in x0 ..= x1 {
					cluster := r3d_cluster_index(x, y, z)

					if counts[cluster] == R3D_MAX_LIGHTS_PER_CLUSTER {
						stats.dropped_entries += 1
						continue
					}

					lists[cluster][counts[cluster]] = u16(i)
					counts[cluster] += 1
				}
			}
		}
	}

	offset := 0
	flat := (^[R3D_MAX_INDEX_ENTRIES]f32)(&textures.indices[0])

	for cluster in 0 ..< R3D_CLUSTER_COUNT {
		count := counts[cluster]

		if offset + count > R3D_MAX_INDEX_ENTRIES {
			stats.dropped_entries += count
			count = 0
		}

		textures.grid[cluster] = {f32(offset), f32(count), 0, 0}

		for k in 0 ..< count {
			flat[offset + k] = f32(lists[cluster][k])
		}

		offset += count
		stats.entries += count
		stats.busiest_cluster = max(stats.busiest_cluster, count)
	}

	return stats
}
