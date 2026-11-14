// RENDER3D: thousands of trees in one instanced draw call. Wind sways the crowns in the vertex shader, every tree grows in by a tween that runs on the GPU (written once per instance), and the CPU culls what is outside the view before the draw. Screenshot mode (-define:R3D_SCREENSHOT=out.png -define:R3D_FRAMES=30) freezes the animation clock for comparisons between backends.
package karl2d_foliage_wind_example

import k2 "../.."
import "core:fmt"
import "core:math"
import "core:math/linalg"

SCREENSHOT :: #config(R3D_SCREENSHOT, "")
FRAMES :: #config(R3D_FRAMES, 0)

TREES_PER_SIDE :: 90
TREE_SPACING :: 2.2

ground: k2.R3d_Mesh
tree: k2.R3d_Mesh
ground_material: k2.R3d_Material
tree_material: k2.R3d_Material

trees: [TREES_PER_SIDE * TREES_PER_SIDE]k2.R3d_Instance
visible: [TREES_PER_SIDE * TREES_PER_SIDE]k2.R3d_Instance
tree_radius: f32

frame: int

hash01 :: proc(n: u32) -> f32 {
	x := n * 747796405 + 2891336453
	x = ((x >> ((x >> 28) + 4)) ~ x) * 277803737
	x = (x >> 22) ~ x
	return f32(x & 0xFFFFFF) / f32(0x1000000)
}

build_tree :: proc() -> k2.R3d_Mesh_Data {
	data: k2.R3d_Mesh_Data

	trunk := k2.r3d_mesh_data_cylinder(0.18, 1.4, 6, {96, 66, 44, 255})
	k2.r3d_mesh_data_append(&data, trunk, k2.r3d_matrix_trs({0, 0.7, 0}, 1, {1, 1, 1}))
	k2.r3d_mesh_data_destroy(&trunk)

	crown_colors := [3]k2.Color{{70, 150, 72, 255}, {82, 168, 82, 255}, {96, 184, 92, 255}}
	crown_sizes := [3]f32{0.95, 0.75, 0.52}

	for i in 0 ..< 3 {
		crown := k2.r3d_mesh_data_sphere(crown_sizes[i], 5, 8, crown_colors[i])
		k2.r3d_mesh_data_append(&data, crown, k2.r3d_matrix_trs({0, 1.7 + f32(i) * 0.85, 0}, 1, {1, 0.85, 1}))
		k2.r3d_mesh_data_destroy(&crown)
	}

	k2.r3d_mesh_data_smooth_outline_normals(&data)
	return data
}

init :: proc() {
	k2.init(1280, 720, "3D foliage and wind", options = {depth_test = true})
	ensure(k2.r3d_init())

	data := k2.r3d_mesh_data_plane({TREES_PER_SIDE * TREE_SPACING * 1.3, TREES_PER_SIDE * TREE_SPACING * 1.3}, {255, 255, 255, 255})
	ground, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	data = build_tree()
	tree_radius = k2.r3d_mesh_data_radius(data)
	tree, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	ground_material = k2.r3d_material_default()
	ground_material.tint = {0.5, 0.66, 0.4, 1}
	ground_material.rim_color = {}

	tree_material = k2.r3d_material_default()
	tree_material.use_vertex_color = true
	tree_material.toon_bands = 3
	tree_material.wind_weight = 1
	tree_material.wind_height = 4.2
	tree_material.rim_color = {1, 0.95, 0.7}
	tree_material.rim_threshold = 0.62

	for i in 0 ..< len(trees) {
		ix, iz := i % TREES_PER_SIDE, i / TREES_PER_SIDE
		jitter := k2.Vec3{hash01(u32(i) * 3 + 1) - 0.5, 0, hash01(u32(i) * 3 + 2) - 0.5} * TREE_SPACING * 0.8
		position := k2.Vec3{(f32(ix) - TREES_PER_SIDE * 0.5) * TREE_SPACING, 0, (f32(iz) - TREES_PER_SIDE * 0.5) * TREE_SPACING} + jitter
		scale := 0.7 + hash01(u32(i) * 3 + 3) * 0.8
		rotation := linalg.quaternion_angle_axis(hash01(u32(i) * 7 + 5) * 2 * math.PI, k2.Vec3{0, 1, 0})
		shade := 0.8 + hash01(u32(i) * 11 + 1) * 0.35
		trees[i] = k2.r3d_instance(position, rotation, {scale, scale, scale}, {shade, shade * (0.9 + hash01(u32(i) + 9) * 0.2), shade, 1})

		k2.r3d_instance_tween(&trees[i], {
			from = 0, to = 1,
			start_time = hash01(u32(i) * 13 + 7) * 2.5,
			duration = 1.4,
			easing = .Out_Back,
			effect = .Scale,
			phase = hash01(u32(i) * 17 + 3) * 6.28,
		})
	}
}

step :: proc() -> bool {
	if !k2.update() {
		return false
	}

	t := f32(k2.get_time())
	if SCREENSHOT != "" {
		t = f32(FRAMES - 1) / 60
	}

	k2.clear({188, 210, 235, 255})

	orbit := t * 0.12
	camera := k2.R3d_Camera {
		position = {math.cos(orbit) * 70, 24, math.sin(orbit) * 70},
		target = {0, 3, 0},
		fov_y_degrees = 58,
		near = 0.3,
		far = 400,
	}

	environment := k2.r3d_environment_default()
	environment.time_override = t
	environment.sun_direction = {0.5, 0.85, 0.35}
	environment.fog_density = 0.008
	environment.fog_start = 40
	environment.wind_direction = {1, 0, 0.4}
	environment.wind_strength = 0.7
	environment.wind_frequency = 1.6
	environment.wind_gust = 0.8

	k2.r3d_begin_scene(camera, environment)
	k2.r3d_draw_one(ground, ground_material, 1)

	visible_count := k2.r3d_cull_instances(visible[:], trees[:], k2.r3d_scene_frustum(), tree_radius, 160)
	k2.r3d_draw(tree, tree_material, visible[:visible_count])
	k2.r3d_end_scene()

	if SCREENSHOT == "" {
		stats := k2.r3d_stats()
		k2.set_z(1)
		k2.draw_text(fmt.tprintf("%v trees, %v drawn after culling, %v draw calls, %v triangles   %.1f ms", len(trees), visible_count, stats.draw_calls, stats.triangles, k2.get_frame_time() * 1000), {12, 10}, 20, k2.BLACK)
		k2.set_z(0)
	}

	k2.r3d_reset_stats()
	frame += 1

	if SCREENSHOT != "" && frame == FRAMES {
		pixels, width, height, ok := k2.r3d_read_pixels({})
		ensure(ok)
		if save_screenshot(SCREENSHOT, pixels, width, height) {
			return false
		}
	}

	k2.present()
	free_all(context.temp_allocator)
	return true
}

shutdown :: proc() {
	k2.r3d_shutdown()
	k2.shutdown()
}

main :: proc() {
	init()
	for step() {}
	shutdown()
}
