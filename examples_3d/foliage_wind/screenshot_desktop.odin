// RENDER3D: screenshot writer of the examples, desktop only (the web build has no file system).
#+build windows, linux, darwin
package karl2d_foliage_wind_example

import "core:strings"
import stbi "vendor:stb/image"

save_screenshot :: proc(path: string, pixels: []u8, width, height: int) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	ensure(stbi.write_png(cpath, i32(width), i32(height), 4, raw_data(pixels), auto_cast (width * 4)) != 0)
	return true
}