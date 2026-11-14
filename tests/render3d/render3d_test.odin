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
