// RENDER3D: CPU culling of instances against the view frustum and a distance limit, writing the visible ones into a caller owned slice so the draw call carries only what can be seen.
package karl2d

import "core:math"
import "core:math/linalg"

R3d_Frustum :: struct {
	planes: [5][4]f32,
	camera_position: Vec3,
}

r3d_frustum_from_view_projection :: proc(view_projection: Mat4, camera_position: Vec3) -> R3d_Frustum {
	row :: proc(m: Mat4, i: int) -> [4]f32 {
		return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}
	}

	r0, r1, r3 := row(view_projection, 0), row(view_projection, 1), row(view_projection, 3)
	raw := [5][4]f32{r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3}
	frustum: R3d_Frustum
	frustum.camera_position = camera_position

	for plane, i in raw {
		length := math.sqrt(plane.x * plane.x + plane.y * plane.y + plane.z * plane.z)
		frustum.planes[i] = plane / max(length, 1e-6)
	}

	return frustum
}

r3d_frustum_contains_sphere :: proc(frustum: R3d_Frustum, center: Vec3, radius: f32) -> bool {
	for plane in frustum.planes {
		if plane.x * center.x + plane.y * center.y + plane.z * center.z + plane.w < -radius {
			return false
		}
	}

	return true
}

r3d_instance_center :: proc(instance: R3d_Instance) -> Vec3 {
	return {instance.row0.w, instance.row1.w, instance.row2.w}
}

r3d_instance_max_scale :: proc(instance: R3d_Instance) -> f32 {
	return max(linalg.length(instance.row0.xyz), linalg.length(instance.row1.xyz), linalg.length(instance.row2.xyz))
}

r3d_cull_instances :: proc(out: []R3d_Instance, instances: []R3d_Instance, frustum: R3d_Frustum, mesh_radius: f32, max_distance: f32 = 0) -> int {
	count := 0

	for instance in instances {
		if count == len(out) {
			break
		}

		center := r3d_instance_center(instance)
		radius := mesh_radius * r3d_instance_max_scale(instance)

		if max_distance > 0 && linalg.length(center - frustum.camera_position) - radius > max_distance {
			continue
		}

		if r3d_frustum_contains_sphere(frustum, center, radius) {
			out[count] = instance
			count += 1
		}
	}

	return count
}
