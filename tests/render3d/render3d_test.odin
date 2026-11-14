// RENDER3D: tests of the 3D layer. Run with: odin test tests/render3d -define:KARL2D_RENDER_BACKEND=nil -define:KARL2D_AUDIO_BACKEND=nil
package render3d_tests

import k2 "../.."
import "core:math"
import "core:math/linalg"
import "core:testing"

@(private="file")
expect_outward_triangles :: proc(t: ^testing.T, name: string, data: k2.R3d_Mesh_Data) {
	bad := 0
	for i := 0; i < len(data.indices); i += 3 {
		a := data.vertices[data.indices[i]]
		b := data.vertices[data.indices[i + 1]]
		c := data.vertices[data.indices[i + 2]]
		face := linalg.cross(b.position - a.position, c.position - a.position)

		if linalg.length2(face) < 1e-12 {
			continue
		}

		if linalg.dot(face, a.normal + b.normal + c.normal) <= 0 {
			bad += 1
		}
	}

	testing.expectf(t, bad == 0, "%v: %v of %v triangles face against their normals (counter clockwise is front)", name, bad, len(data.indices) / 3)
}

@(test)
test_mesh_builders_wind_counter_clockwise_outward :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	shapes := [?]struct{ name: string, data: k2.R3d_Mesh_Data } {
		{"cube", k2.r3d_mesh_data_cube({2, 3, 4})},
		{"plane", k2.r3d_mesh_data_plane()},
		{"sphere", k2.r3d_mesh_data_sphere()},
		{"cylinder", k2.r3d_mesh_data_cylinder()},
	}

	for shape in shapes {
		expect_outward_triangles(t, shape.name, shape.data)
		testing.expect(t, len(shape.data.indices) % 3 == 0)

		for index in shape.data.indices {
			testing.expect(t, int(index) < len(shape.data.vertices))
		}

		for v in shape.data.vertices {
			testing.expectf(t, abs(linalg.length(v.normal) - 1) < 1e-4, "%v: normal length %v", shape.name, linalg.length(v.normal))
		}
	}
}

@(test)
test_outline_normals_close_hard_edges :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	data := k2.r3d_mesh_data_cube({2, 2, 2})
	corner_x: f32

	for v in data.vertices {
		if v.position == {1, 1, 1} {
			corner_x += f32(v.outline_normal.x)
			testing.expect(t, v.outline_normal.x > 0 && v.outline_normal.y > 0 && v.outline_normal.z > 0, "the outline normal of a cube corner points out of the corner")
		}
	}

	testing.expect(t, corner_x > 0)
}

@(private="file")
project :: proc(m: k2.Mat4, p: k2.Vec3) -> (z_over_w: f32) {
	v := m * [4]f32{p.x, p.y, p.z, 1}
	return v.z / v.w
}

@(test)
test_reverse_z_perspective_for_both_clip_ranges :: proc(t: ^testing.T) {
	ranges := [?][2]f32{{0, 1}, {-1, 1}}

	for range in ranges {
		m := k2.r3d_matrix_perspective(math.to_radians(f32(60)), 1.5, 0.1, range[0], range[1])
		at_near := project(m, {0, 0, -0.1})
		at_far := project(m, {0, 0, -100000})
		in_between := project(m, {0, 0, -5})

		testing.expectf(t, abs(at_near - range[1]) < 1e-4, "near plane maps to %v, got %v", range[1], at_near)
		testing.expectf(t, abs(at_far - range[0]) < 1e-3, "far maps to %v, got %v", range[0], at_far)
		testing.expect(t, in_between < at_near && in_between > at_far, "depth decreases with distance (reversed z)")
	}
}

@(test)
test_reverse_z_ortho :: proc(t: ^testing.T) {
	m := k2.r3d_matrix_ortho(-5, 5, -5, 5, 1, 11, 0, 1)
	testing.expect(t, abs(project(m, {0, 0, -1}) - 1) < 1e-5)
	testing.expect(t, abs(project(m, {0, 0, -11}) - 0) < 1e-5)
	testing.expect(t, abs(project(m, {0, 0, -6}) - 0.5) < 1e-5)
}

@(test)
test_look_at_puts_the_target_in_front_of_the_camera :: proc(t: ^testing.T) {
	view := k2.r3d_matrix_look_at({0, 0, 5}, {0, 0, 0}, {0, 1, 0})
	origin := view * [4]f32{0, 0, 0, 1}
	testing.expect(t, abs(origin.x) < 1e-5 && abs(origin.y) < 1e-5 && abs(origin.z + 5) < 1e-5, "the origin is 5 units down the view -z axis")
	right := view * [4]f32{1, 0, 5, 1}
	testing.expect(t, right.x > 0.99, "world +x is screen right")
	up := view * [4]f32{0, 1, 5, 1}
	testing.expect(t, up.y > 0.99, "world +y is screen up")

	elevated := k2.r3d_matrix_look_at({3, 4, 5}, {1, 1, 0}, {0, 1, 0})
	target := elevated * [4]f32{1, 1, 0, 1}
	testing.expect(t, abs(target.x) < 1e-4 && abs(target.y) < 1e-4 && target.z < 0, "the target stays on the view axis")
}

@(test)
test_instances_carry_the_transform_rows :: proc(t: ^testing.T) {
	m := k2.r3d_matrix_trs({1, 2, 3}, linalg.quaternion_angle_axis(math.PI * 0.5, k2.Vec3{0, 1, 0}), {2, 2, 2})
	instance := k2.r3d_instance_from_matrix(m, {0.5, 0.25, 1, 1})
	point := k2.Vec3{1, 0, 0}
	moved := k2.Vec3 {
		linalg.dot(instance.row0.xyz, point) + instance.row0.w,
		linalg.dot(instance.row1.xyz, point) + instance.row1.w,
		linalg.dot(instance.row2.xyz, point) + instance.row2.w,
	}
	expected := (m * [4]f32{point.x, point.y, point.z, 1}).xyz
	testing.expect(t, linalg.length(moved - expected) < 1e-5, "the three rows transform a point like the matrix does")
	testing.expect_value(t, instance.tint, [4]f32{0.5, 0.25, 1, 1})
}

@(test)
test_default_material_and_environment_are_usable :: proc(t: ^testing.T) {
	material := k2.r3d_material_default()
	testing.expect(t, material.toon_bands >= 1 && material.tint.a == 1)
	environment := k2.r3d_environment_default()
	testing.expect(t, linalg.length(environment.sun_direction) > 0)
}

@(test)
test_easing_functions_hit_their_ends_and_are_monotonic :: proc(t: ^testing.T) {
	for easing in k2.R3d_Easing {
		testing.expectf(t, abs(k2.r3d_ease(easing, 0)) < 1e-6, "%v starts at 0", easing)
		testing.expectf(t, abs(k2.r3d_ease(easing, 1) - 1) < 1e-5, "%v ends at 1", easing)
		testing.expect_value(t, k2.r3d_ease(easing, -3), k2.r3d_ease(easing, 0))
		testing.expect_value(t, k2.r3d_ease(easing, 5), k2.r3d_ease(easing, 1))

		if easing == .Out_Back {
			continue
		}

		previous: f32
		for i in 0 ..= 100 {
			value := k2.r3d_ease(easing, f32(i) / 100)
			testing.expectf(t, value >= previous - 1e-6, "%v is not monotonic at step %v", easing, i)
			previous = value
		}
	}

	testing.expect_value(t, k2.r3d_ease(.In_Quad, 0.5), 0.25)
	testing.expect_value(t, k2.r3d_ease(.Out_Quad, 0.5), 0.75)
	testing.expect_value(t, k2.r3d_ease(.In_Out_Quad, 0.5), 0.5)
	testing.expect(t, k2.r3d_ease(.Out_Back, 0.8) > 1, "out back overshoots")
}

@(test)
test_tween_progress_and_loop_modes :: proc(t: ^testing.T) {
	tween := k2.R3d_Tween{from = 10, to = 20, start_time = 2, duration = 4}
	testing.expect_value(t, k2.r3d_tween_value(tween, 0), 10)
	testing.expect_value(t, k2.r3d_tween_value(tween, 4), 15)
	testing.expect_value(t, k2.r3d_tween_value(tween, 100), 20)

	tween.loop = .Loop
	testing.expect_value(t, k2.r3d_tween_value(tween, 2 + 4 + 1), 12.5)
	testing.expect_value(t, k2.r3d_tween_value(tween, 1), 10)

	tween.loop = .Ping_Pong
	testing.expect_value(t, k2.r3d_tween_value(tween, 2 + 3), 17.5)
	testing.expect_value(t, k2.r3d_tween_value(tween, 2 + 4 + 1), 17.5)
	testing.expect_value(t, k2.r3d_tween_value(tween, 2 + 8), 10)

	still := k2.R3d_Tween{from = 3, to = 9}
	testing.expect_value(t, k2.r3d_tween_progress(still, 5), 1)
}

@(test)
test_tween_is_packed_into_the_instance_params :: proc(t: ^testing.T) {
	instance := k2.r3d_instance({1, 2, 3})
	k2.r3d_instance_tween(&instance, {from = 0, to = 1, start_time = 0.5, duration = 2, easing = .Out_Back, effect = .Scale, loop = .Ping_Pong, phase = 1.25})
	testing.expect_value(t, instance.params[0], [4]f32{0, 1, 0.5, 2})
	testing.expect_value(t, instance.params[1], [4]f32{f32(k2.R3d_Easing.Out_Back), f32(k2.R3d_Tween_Effect.Scale), f32(k2.R3d_Tween_Loop.Ping_Pong), 1.25})
	k2.r3d_instance_set_phase(&instance, 4)
	testing.expect_value(t, instance.params[1].w, 4)
	testing.expect_value(t, size_of(k2.R3d_Instance), 128)
}

@(test)
test_culling_keeps_what_is_in_view :: proc(t: ^testing.T) {
	camera := k2.R3d_Camera{position = {0, 0, 10}, target = {0, 0, 0}, fov_y_degrees = 60, near = 0.1, far = 100}
	clip_ranges := [?][2]f32{{0, 1}, {-1, 1}}

	for range in clip_ranges {
		view, projection := k2.r3d_camera_matrices(camera, 16.0 / 9.0, range[0], range[1])
		frustum := k2.r3d_frustum_from_view_projection(projection * view, camera.position)

		testing.expect(t, k2.r3d_frustum_contains_sphere(frustum, {0, 0, 0}, 0.5), "the target is in view")
		testing.expect(t, !k2.r3d_frustum_contains_sphere(frustum, {0, 0, 40}, 0.5), "behind the camera")
		testing.expect(t, !k2.r3d_frustum_contains_sphere(frustum, {60, 0, 0}, 0.5), "far to the right")
		testing.expect(t, !k2.r3d_frustum_contains_sphere(frustum, {-60, 0, 0}, 0.5), "far to the left")
		testing.expect(t, !k2.r3d_frustum_contains_sphere(frustum, {0, -60, 0}, 0.5), "far below")
		testing.expect(t, !k2.r3d_frustum_contains_sphere(frustum, {0, 60, 0}, 0.5), "far above")
		testing.expect(t, k2.r3d_frustum_contains_sphere(frustum, {-7.4, 0, 0}, 3), "a big sphere overlapping the left edge stays")
		testing.expect(t, k2.r3d_frustum_contains_sphere(frustum, {7.4, 0, 0}, 3), "a big sphere overlapping the edge stays")

		instances := [?]k2.R3d_Instance {
			k2.r3d_instance({0, 0, 0}),
			k2.r3d_instance({0, 0, 40}),
			k2.r3d_instance({3, 1, -20}),
			k2.r3d_instance({0, 0, -80}, scale = {1, 1, 1}),
			k2.r3d_instance({100, 0, 0}),
		}
		out: [5]k2.R3d_Instance
		count := k2.r3d_cull_instances(out[:], instances[:], frustum, 1)
		testing.expectf(t, count == 3, "clip range %v: %v instances kept, expected the three in front", range, count)

		limited := k2.r3d_cull_instances(out[:], instances[:], frustum, 1, 50)
		testing.expectf(t, limited == 2, "with a distance limit of 50, %v kept (the one at 90 units goes)", limited)

		small: [1]k2.R3d_Instance
		testing.expect_value(t, k2.r3d_cull_instances(small[:], instances[:], frustum, 1), 1)
	}

	scaled := k2.r3d_instance({0, 0, 0}, scale = {4, 2, 3})
	testing.expect_value(t, k2.r3d_instance_max_scale(scaled), 4)
	testing.expect_value(t, k2.r3d_instance_center(k2.r3d_instance({1, 2, 3})), k2.Vec3{1, 2, 3})
}

@(test)
test_mesh_append_transforms_and_offsets :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cube := k2.r3d_mesh_data_cube({1, 1, 1})
	merged: k2.R3d_Mesh_Data
	k2.r3d_mesh_data_append(&merged, cube)
	k2.r3d_mesh_data_append(&merged, cube, k2.r3d_matrix_trs({10, 0, 0}, 1, {2, 2, 2}), k2.Color{1, 2, 3, 4})

	testing.expect_value(t, len(merged.vertices), 2 * len(cube.vertices))
	testing.expect_value(t, len(merged.indices), 2 * len(cube.indices))
	testing.expect_value(t, merged.indices[len(cube.indices)], u32(len(cube.vertices)) + cube.indices[0])

	moved := merged.vertices[len(cube.vertices)]
	original := cube.vertices[0]
	testing.expect(t, linalg.length(moved.position - (original.position * 2 + k2.Vec3{10, 0, 0})) < 1e-5, "positions are scaled and moved")
	testing.expect(t, linalg.length(moved.normal - original.normal) < 1e-5, "normals keep their direction")
	testing.expect_value(t, moved.color, k2.Color{1, 2, 3, 4})
	testing.expect(t, abs(k2.r3d_mesh_data_radius(cube) - math.sqrt(f32(0.75))) < 1e-5)
}

@(test)
test_material_wind_reaches_the_gpu_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(k2.R3d_Material_Constants), 144)
	testing.expect_value(t, size_of(k2.R3d_Material_Constants) % 16, 0)
	testing.expect_value(t, size_of(k2.R3d_Globals) % 16, 0)
	material := k2.r3d_material_default()
	testing.expect_value(t, material.wind_weight, 0)
	testing.expect(t, material.wind_height > 0)
}
