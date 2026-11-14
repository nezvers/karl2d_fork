// RENDER3D: per-instance tweens. The CPU writes four numbers per instance once (r3d_instance_tween), the vertex/pixel shader evaluates the tween every frame from the global time, so animated instances cost no CPU and no re-upload. The easing functions here and in the shaders are the same formulas.
package karl2d

import "core:math"

R3d_Easing :: enum u8 {
	Linear,
	In_Quad,
	Out_Quad,
	In_Out_Quad,
	Out_Back,
}

R3d_Tween_Effect :: enum u8 {
	None,
	Scale,
	Fade,
	Rise,
	Flash,
}

R3d_Tween_Loop :: enum u8 {
	Clamp,
	Loop,
	Ping_Pong,
}

R3d_Tween :: struct {
	from: f32,
	to: f32,
	start_time: f32,
	duration: f32,
	easing: R3d_Easing,
	effect: R3d_Tween_Effect,
	loop: R3d_Tween_Loop,
	phase: f32,
}

r3d_ease :: proc(easing: R3d_Easing, t: f32) -> f32 {
	x := clamp(t, 0, 1)

	switch easing {
	case .Linear: return x
	case .In_Quad: return x * x
	case .Out_Quad: return 1 - (1 - x) * (1 - x)
	case .In_Out_Quad:
		if x < 0.5 {
			return 2 * x * x
		}
		return 1 - 2 * (1 - x) * (1 - x)
	case .Out_Back:
		c1: f32 = 1.70158
		c3 := c1 + 1
		d := x - 1
		return 1 + c3 * d * d * d + c1 * d * d
	}

	return x
}

r3d_tween_progress :: proc(tween: R3d_Tween, time: f32) -> f32 {
	if tween.duration <= 0 {
		return 1
	}

	u := (time - tween.start_time) / tween.duration

	switch tween.loop {
	case .Clamp:
		u = clamp(u, 0, 1)
	case .Loop:
		u = max(u, 0)
		u = u - math.floor(u)
	case .Ping_Pong:
		u = max(u, 0)
		m := (u * 0.5 - math.floor(u * 0.5)) * 2
		u = m if m < 1 else 2 - m
	}

	return u
}

r3d_tween_value :: proc(tween: R3d_Tween, time: f32) -> f32 {
	return tween.from + (tween.to - tween.from) * r3d_ease(tween.easing, r3d_tween_progress(tween, time))
}

r3d_instance_tween :: proc(instance: ^R3d_Instance, tween: R3d_Tween) {
	instance.params[0] = {tween.from, tween.to, tween.start_time, tween.duration}
	instance.params[1] = {f32(tween.easing), f32(tween.effect), f32(tween.loop), tween.phase}
}

r3d_instance_set_phase :: proc(instance: ^R3d_Instance, phase: f32) {
	instance.params[1].w = phase
}
