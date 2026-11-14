// RENDER3D: toon lit scene with rim light, outlines and fog, many instances per draw call. Build with -define:R3D_SCREENSHOT=out.png -define:R3D_FRAMES=30 to render a few frames, write the last one as a PNG and exit.
package karl2d_toon_scene_example

import k2 "../.."
import "core:fmt"
import "core:math"
import "core:math/linalg"

SCREENSHOT :: #config(R3D_SCREENSHOT, "")
FRAMES :: #config(R3D_FRAMES, 0)

ground: k2.R3d_Mesh
cube: k2.R3d_Mesh
sphere: k2.R3d_Mesh
cylinder: k2.R3d_Mesh

ground_material: k2.R3d_Material
cube_material: k2.R3d_Material
sphere_material: k2.R3d_Material
cylinder_material: k2.R3d_Material

frame: int

init :: proc() {
	k2.init(1280, 720, "3D toon scene", options = {depth_test = true})
	ensure(k2.r3d_init())

	data := k2.r3d_mesh_data_plane({60, 60})
	ground, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	data = k2.r3d_mesh_data_cube({1, 1, 1})
	cube, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	data = k2.r3d_mesh_data_sphere(1, 24, 32)
	sphere, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	data = k2.r3d_mesh_data_cylinder(0.5, 2, 24)
	cylinder, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	ground_material = k2.r3d_material_default()
	ground_material.tint = {0.45, 0.62, 0.38, 1}
	ground_material.rim_color = {}

	cube_material = k2.r3d_material_default()
	cube_material.outline_width = 2.5
	cube_material.toon_bands = 3

	sphere_material = k2.r3d_material_default()
	sphere_material.tint = {1, 0.55, 0.35, 1}
	sphere_material.outline_width = 3.5
	sphere_material.toon_bands = 4
	sphere_material.specular_color = {1, 1, 1}
	sphere_material.specular_power = 60
	sphere_material.rim_color = {1, 0.8, 0.6}

	cylinder_material = k2.r3d_material_default()
	cylinder_material.tint = {0.55, 0.7, 1, 1}
	cylinder_material.outline_width = 2
	cylinder_material.toon_bands = 2
}

step :: proc() -> bool {
	if !k2.update() {
		return false
	}

	t := f32(k2.get_time())
	k2.clear({182, 205, 232, 255})

	camera := k2.R3d_Camera {
		position = {math.cos(t * 0.25) * 16, 7, math.sin(t * 0.25) * 16},
		target = {0, 1.2, 0},
		fov_y_degrees = 55,
		near = 0.1,
	}

	environment := k2.r3d_environment_default()
	environment.sun_direction = {math.cos(t * 0.4), 0.9, math.sin(t * 0.4)}
	environment.fog_density = 0.012
	environment.fog_start = 14

	k2.r3d_begin_scene(camera, environment)

	k2.r3d_draw_one(ground, ground_material, 1)

	cubes: [64]k2.R3d_Instance
	for i in 0 ..< len(cubes) {
		angle := f32(i) / f32(len(cubes)) * 2 * math.PI
		radius := f32(9) + f32(i % 3) * 1.4
		height := 0.5 + (math.sin(angle * 3 + t) * 0.5 + 0.5) * 1.5
		position := k2.Vec3{math.cos(angle) * radius, height * 0.5, math.sin(angle) * radius}
		rotation := linalg.quaternion_angle_axis(angle + t * 0.3, k2.Vec3{0, 1, 0})
		hue := f32(i) / f32(len(cubes))
		tint := [4]f32{0.55 + 0.45 * math.sin(hue * 6.28), 0.55 + 0.45 * math.sin(hue * 6.28 + 2.1), 0.55 + 0.45 * math.sin(hue * 6.28 + 4.2), 1}
		cubes[i] = k2.r3d_instance(position, rotation, {1, height, 1}, tint)
	}
	k2.r3d_draw(cube, cube_material, cubes[:])

	k2.r3d_draw_one(sphere, sphere_material, k2.r3d_matrix_trs({0, 1.6 + math.sin(t) * 0.3, 0}, 1, {1.6, 1.6, 1.6}))

	cylinders: [6]k2.R3d_Instance
	for i in 0 ..< len(cylinders) {
		angle := f32(i) / f32(len(cylinders)) * 2 * math.PI + t * 0.2
		cylinders[i] = k2.r3d_instance({math.cos(angle) * 4.5, 1, math.sin(angle) * 4.5})
	}
	k2.r3d_draw(cylinder, cylinder_material, cylinders[:])

	k2.r3d_end_scene()

	stats := k2.r3d_stats()
	k2.set_z(1)
	k2.draw_text(fmt.tprintf("3D: %v draw calls, %v instances, %v triangles   %.1f ms", stats.draw_calls, stats.instances, stats.triangles, k2.get_frame_time() * 1000), {12, 10}, 20, k2.BLACK)
	k2.r3d_reset_stats()
	k2.set_z(0)

	frame += 1

	if SCREENSHOT != "" && frame >= FRAMES {
		pixels, width, height, ok := k2.r3d_read_pixels({})
		ensure(ok)
		save_screenshot(SCREENSHOT, pixels, width, height)
		return false
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
