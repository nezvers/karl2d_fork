// RENDER3D: picks the 3D backend that belongs to the karl2d render backend. Backends without a 3D implementation fall back to the nil one.
package karl2d

when RENDER_BACKEND_NAME == "d3d11" {
	R3D_BACKEND :: R3D_BACKEND_D3D11
	R3D_BACKEND_AVAILABLE :: true
} else when RENDER_BACKEND_NAME == "gl" {
	R3D_BACKEND :: R3D_BACKEND_GL
	R3D_BACKEND_AVAILABLE :: true
} else when RENDER_BACKEND_NAME == "webgl" {
	R3D_BACKEND :: R3D_BACKEND_WEBGL
	R3D_BACKEND_AVAILABLE :: true
} else {
	R3D_BACKEND :: R3D_BACKEND_NIL
	R3D_BACKEND_AVAILABLE :: RENDER_BACKEND_NAME == "nil"
}
