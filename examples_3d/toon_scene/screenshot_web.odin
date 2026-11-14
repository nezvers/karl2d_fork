// RENDER3D: the web build has no file system, so a screenshot request only freezes the animation at the requested frame there (a browser screenshot can then capture it).
#+build js
package karl2d_toon_scene_example

save_screenshot :: proc(path: string, pixels: []u8, width, height: int) -> bool {
	return false
}