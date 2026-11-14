// RENDER3D: 256 colored point lights and a few spot lights in one forward pass. The CPU bins the lights into view clusters, the pixel shader loops over only the lights of its cluster. Screenshot mode (-define:R3D_SCREENSHOT=out.png -define:R3D_FRAMES=30) freezes the animation clock for comparisons between backends.
package karl2d_lights_example

import k2 "../.."
import "core:fmt"
import "core:math"
import "core:math/linalg"

SCREENSHOT :: #config(R3D_SCREENSHOT, "")
FRAMES :: #config(R3D_FRAMES, 0)

POINT_LIGHTS :: 256
SPOT_LIGHTS :: 4
CUBES :: 160

ground: k2.R3d_Mesh
cube: k2.R3d_Mesh
orb: k2.R3d_Mesh
ground_material: k2.R3d_Material
cube_material: k2.R3d_Material
orb_material: k2.R3d_Material

cubes: [CUBES]k2.R3d_Instance
lights: [POINT_LIGHTS + SPOT_LIGHTS]k2.R3d_Light
orbs: [POINT_LIGHTS]k2.R3d_Instance

frame: int

hash01 :: proc(n: u32) -> f32 {
	x := n * 747796405 + 2891336453
	x = ((x >> ((x >> 28) + 4)) ~ x) * 277803737
	x = (x >> 22) ~ x
	return f32(x & 0xFFFFFF) / f32(0x1000000)
}

hsv :: proc(h: f32) -> k2.Vec3 {
	return {0.55 + 0.45 * math.sin(h * 6.283), 0.55 + 0.45 * math.sin(h * 6.283 + 2.1), 0.55 + 0.45 * math.sin(h * 6.283 + 4.2)}
}

init :: proc() {
	k2.init(1280, 720, "3D clustered lights", options = {depth_test = true})
	ensure(k2.r3d_init())

	data := k2.r3d_mesh_data_plane({90, 90})
	ground, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	data = k2.r3d_mesh_data_cube({1, 1, 1})
	cube, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	data = k2.r3d_mesh_data_sphere(0.16, 4, 6)
	orb, _ = k2.r3d_mesh_create_from_data(data)
	k2.r3d_mesh_data_destroy(&data)

	ground_material = k2.r3d_material_default()
	ground_material.tint = {0.8, 0.8, 0.84, 1}
	ground_material.rim_color = {}
	ground_material.toon_bands = 4

	cube_material = k2.r3d_material_default()
	cube_material.tint = {0.9, 0.9, 0.95, 1}
	cube_material.toon_bands = 3
	cube_material.rim_color = {}

	orb_material = k2.r3d_material_default()
	orb_material.unlit = true
	orb_material.rim_color = {}

	for i in 0 ..< CUBES {
		x := (hash01(u32(i) * 3 + 1) - 0.5) * 70
		z := (hash01(u32(i) * 3 + 2) - 0.5) * 70
		height := 1 + hash01(u32(i) * 3 + 3) * 4
		cubes[i] = k2.r3d_instance({x, height * 0.5, z}, linalg.quaternion_angle_axis(hash01(u32(i) + 99) * 3, k2.Vec3{0, 1, 0}), {1.2 + hash01(u32(i) + 5), height, 1.2 + hash01(u32(i) + 7)})
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

	k2.clear({20, 22, 36, 255})

	for i in 0 ..< POINT_LIGHTS {
		seed := u32(i)
		radius := 6 + hash01(seed * 5 + 1) * 28
		speed := (0.15 + hash01(seed * 5 + 2) * 0.4) * (1 if i % 2 == 0 else -1)
		angle := hash01(seed * 5 + 3) * 6.283 + t * speed
		color := hsv(hash01(seed * 5 + 4))
		position := k2.Vec3{math.cos(angle) * radius, 0.9 + hash01(seed * 5 + 6) * 1.2, math.sin(angle) * radius}
		lights[i] = {position = position, radius = 5, color = color, intensity = 0.6}
		orbs[i] = k2.r3d_instance(position, 1, {1, 1, 1}, {color.x, color.y, color.z, 1})
	}

	for i in 0 ..< SPOT_LIGHTS {
		angle := f32(i) / SPOT_LIGHTS * 6.283 + t * 0.3
		position := k2.Vec3{math.cos(angle) * 14, 7, math.sin(angle) * 14}
		lights[POINT_LIGHTS + i] = {
			position = position, radius = 16, color = {1, 0.95, 0.8}, intensity = 1.2,
			direction = k2.Vec3{-math.cos(angle) * 0.5, -1, -math.sin(angle) * 0.5},
			spot_outer_degrees = 30, spot_inner_degrees = 18,
		}
	}

	camera := k2.R3d_Camera {
		position = {math.cos(t * 0.1) * 34, 17, math.sin(t * 0.1) * 34},
		target = {0, 1, 0},
		fov_y_degrees = 58,
		near = 0.3,
		far = 150,
	}

	environment := k2.r3d_environment_default()
	environment.time_override = t
	environment.sun_color = {0.12, 0.13, 0.2}
	environment.sun_direction = {0.3, 1, 0.2}
	environment.ambient_sky = {0.1, 0.11, 0.18}
	environment.ambient_ground = {0.05, 0.05, 0.08}
	environment.fog_color = {0.08, 0.09, 0.14}
	environment.fog_density = 0.012
	environment.fog_start = 30

	k2.r3d_begin_scene(camera, environment, lights[:])
	k2.r3d_draw_one(ground, ground_material, 1)
	k2.r3d_draw(cube, cube_material, cubes[:])
	k2.r3d_draw(orb, orb_material, orbs[:])
	k2.r3d_end_scene()

	if SCREENSHOT == "" {
		stats := k2.r3d_light_stats()
		draw := k2.r3d_stats()
		k2.set_z(1)
		k2.draw_text(fmt.tprintf("%v lights, %v cluster entries (busiest %v), %v draw calls   %.1f ms", stats.lights, stats.entries, stats.busiest_cluster, draw.draw_calls, k2.get_frame_time() * 1000), {12, 10}, 20, k2.WHITE)
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