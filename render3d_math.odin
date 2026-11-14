// RENDER3D: matrices for the 3D layer. Depth is reversed: near maps to the far clip value of the backend, so the global GREATER_EQUAL depth test with a clear of 0 keeps working.
package karl2d

import "core:math"
import "core:math/linalg"

r3d_matrix_perspective :: proc(fov_y_radians, aspect, near, clip_z_min, clip_z_max: f32) -> Mat4 {
	f := 1 / math.tan(fov_y_radians * 0.5)
	m: Mat4
	m[0, 0] = f / aspect
	m[1, 1] = f
	m[2, 2] = -clip_z_min
	m[2, 3] = (clip_z_max - clip_z_min) * near
	m[3, 2] = -1
	return m
}

r3d_matrix_ortho :: proc(left, right, bottom, top, near, far, clip_z_min, clip_z_max: f32) -> Mat4 {
	m: Mat4
	scale := (clip_z_max - clip_z_min) / (far - near)
	m[0, 0] = 2 / (right - left)
	m[1, 1] = 2 / (top - bottom)
	m[2, 2] = scale
	m[2, 3] = clip_z_min + scale * far
	m[0, 3] = -(right + left) / (right - left)
	m[1, 3] = -(top + bottom) / (top - bottom)
	m[3, 3] = 1
	return m
}

r3d_matrix_look_at :: proc(eye, target, up: Vec3) -> Mat4 {
	f := linalg.normalize(target - eye)
	r := linalg.normalize(linalg.cross(f, up))
	u := linalg.cross(r, f)
	m: Mat4
	m[0, 0], m[0, 1], m[0, 2], m[0, 3] = r.x, r.y, r.z, -linalg.dot(r, eye)
	m[1, 0], m[1, 1], m[1, 2], m[1, 3] = u.x, u.y, u.z, -linalg.dot(u, eye)
	m[2, 0], m[2, 1], m[2, 2], m[2, 3] = -f.x, -f.y, -f.z, linalg.dot(f, eye)
	m[3, 3] = 1
	return m
}

r3d_matrix_trs :: proc(position: Vec3, rotation: quaternion128, scale: Vec3) -> Mat4 {
	return linalg.matrix4_from_trs(position, rotation, scale)
}

r3d_camera_matrices :: proc(camera: R3d_Camera, aspect: f32, clip_z_min, clip_z_max: f32) -> (view, projection: Mat4) {
	up := camera.up
	if up == {} {
		up = {0, 1, 0}
	}

	near := camera.near
	if near <= 0 {
		near = 0.1
	}

	view = r3d_matrix_look_at(camera.position, camera.target, up)

	if camera.orthographic {
		half_h := camera.ortho_height * 0.5
		if half_h <= 0 {
			half_h = 5
		}
		far := camera.far
		if far <= near {
			far = near + 1000
		}
		projection = r3d_matrix_ortho(-half_h * aspect, half_h * aspect, -half_h, half_h, near, far, clip_z_min, clip_z_max)
		return
	}

	fov := camera.fov_y_degrees
	if fov <= 0 {
		fov = 60
	}
	projection = r3d_matrix_perspective(math.to_radians(fov), aspect, near, clip_z_min, clip_z_max)
	return
}

r3d_instance_from_matrix :: proc(m: Mat4, tint: [4]f32 = {1, 1, 1, 1}) -> R3d_Instance {
	return {
		row0 = {m[0, 0], m[0, 1], m[0, 2], m[0, 3]},
		row1 = {m[1, 0], m[1, 1], m[1, 2], m[1, 3]},
		row2 = {m[2, 0], m[2, 1], m[2, 2], m[2, 3]},
		tint = tint,
	}
}

r3d_instance :: proc(position: Vec3, rotation: quaternion128 = 1, scale: Vec3 = {1, 1, 1}, tint: [4]f32 = {1, 1, 1, 1}) -> R3d_Instance {
	return r3d_instance_from_matrix(r3d_matrix_trs(position, rotation, scale), tint)
}
