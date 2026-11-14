// RENDER3D: the only file of the 3D layer that reaches into karl2d internals besides the backend files. After a rebase on upstream, compile errors show up here first.
package karl2d

r3d_karl2d_state :: proc() -> ^State {
	state := get_internal_state()
	assert(state != nil, "karl2d must be initialized before the 3D layer")
	return state
}
