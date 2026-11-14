// RENDER3D: checks of the 3D layer, run from the root of the karl2d fork:
//   odin run tools/render3d_check              everything
//   odin run tools/render3d_check -- --quick   type checks and tests only (a few seconds)
//   odin run tools/render3d_check -- --no-web  everything except the html5 build and the browser capture
//   odin test tools/render3d_check             the tests of this tool (image comparison)
// What it does: type checks every example in examples_3d for D3D11, GL, macOS and html5; runs tests/render3d on the headless nil
// backend; builds every example for D3D11 and for GL, runs both in screenshot mode (a frozen clock, so the frame is deterministic) and
// compares the two screenshots; builds the html5 version, captures it with headless Edge/Chrome (from the file system, software
// rasterizer) and compares it with the D3D11 screenshot at a coarse 48x27 grid, because the browser renders at another
// resolution. The comparisons need Windows (D3D11 and GL) and, for html5, an installed Edge or Chrome (skipped otherwise).
// Output is one line per check (ok, FAIL, skip); the exit code is 1 when anything failed. odin_plug runs this tool from
// `odin run tools/dev -- karl2d` and as a step of `dev verify`.
package karl2d_render3d_check

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

EXAMPLES := [?]string{"toon_scene", "foliage_wind", "lights"}

TYPE_CHECKS := [?]struct {
	label: string,
	flags: []string,
}{
	{"d3d11 (windows)", {}},
	{"gl (windows)", {"-define:KARL2D_RENDER_BACKEND=gl"}},
	{"darwin_arm64", {"-target:darwin_arm64"}},
	{"js_wasm32 (html5)", {"-target:js_wasm32"}},
}

BROWSER_PATHS := [?]string{
	"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
	"C:/Program Files/Microsoft/Edge/Application/msedge.exe",
	"C:/Program Files/Google/Chrome/Application/chrome.exe",
}

failures: int

check_ok :: proc(format: string, args: ..any) {
	fmt.printf("ok    ")
	fmt.printfln(format, ..args)
}

check_skip :: proc(format: string, args: ..any) {
	fmt.printf("skip  ")
	fmt.printfln(format, ..args)
}

check_fail :: proc(format: string, args: ..any) {
	failures += 1
	fmt.printf("FAIL  ")
	fmt.printfln(format, ..args)
}

show_lines :: proc(lines: []string, count: int) {
	for line, i in lines {
		if i == count { break }
		fmt.printfln("      %s", line)
	}
}

// Runs a program with both output streams captured
run :: proc(command: []string, working_dir: string = "") -> (code: int, lines: []string) {
	state, stdout, stderr, error := os.process_exec({command = command, working_dir = working_dir}, context.allocator)

	if error != nil {
		message := make([]string, 1)
		message[0] = fmt.aprintf("could not run %s: %v", command[0], error)
		return -1, message
	}

	text := strings.concatenate({string(stdout), "\n", string(stderr)})
	all := strings.split_lines(text)

	for len(all) > 0 && strings.trim_space(all[len(all) - 1]) == "" {
		all = all[:len(all) - 1]
	}

	return state.exit_code, all
}

// Gives up after `seconds` (the program is killed, -2): for programs that open windows and could hang
run_with_timeout :: proc(command: []string, seconds: int, working_dir: string = "") -> int {
	process, start_error := os.process_start({command = command, working_dir = working_dir})

	if start_error != nil {
		return -1
	}

	state, wait_error := os.process_wait(process, time.Duration(seconds) * time.Second)

	if wait_error != nil || !state.exited {
		if kill_error := os.process_kill(process); kill_error != nil {
			return -2
		}

		_, _ = os.process_wait(process)
		return -2
	}

	return state.exit_code
}

// The count of "Finished 29 tests in 1.2s." (the number of tests), "" when the line is not that summary
test_summary_count :: proc(line: string) -> string {
	if !strings.has_prefix(line, "Finished ") {
		return ""
	}

	rest := line[len("Finished "):]
	digits := 0

	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits += 1
	}

	if digits == 0 || !strings.has_prefix(rest[digits:], " test") {
		return ""
	}

	return rest[:digits]
}

// How far two RGBA8 images are apart: the mean absolute difference per channel (0..255) and the share of pixels where any channel differs by more than `threshold`
image_difference :: proc(a, b: []u8, threshold: int) -> (mean: f64, far_share: f64) {
	assert(len(a) == len(b) && len(a) % 4 == 0)
	total, far: int

	for i := 0; i < len(a); i += 4 {
		biggest: int

		for c in 0 ..< 4 {
			d := abs(int(a[i + c]) - int(b[i + c]))
			total += d
			biggest = max(biggest, d)
		}

		if biggest > threshold {
			far += 1
		}
	}

	pixels := max(len(a) / 4, 1)
	return f64(total) / f64(len(a)), f64(far) / f64(pixels)
}

// Mean colour of each cell of a gx x gy grid laid over an RGBA8 image (a resolution independent summary of the picture)
grid_means :: proc(pixels: []u8, width, height, gx, gy: int) -> []f32 {
	means := make([]f32, gx * gy * 3)
	counts := make([]int, gx * gy)

	for y in 0 ..< height {
		for x in 0 ..< width {
			cell := (y * gy / height) * gx + (x * gx / width)
			counts[cell] += 1
			for c in 0 ..< 3 { means[cell * 3 + c] += f32(pixels[(y * width + x) * 4 + c]) }
		}
	}

	for cell in 0 ..< gx * gy {
		for c in 0 ..< 3 { means[cell * 3 + c] /= f32(max(counts[cell], 1)) }
	}

	return means
}

mean_grid_difference :: proc(a, b: []f32) -> f64 {
	total: f64
	for i in 0 ..< len(a) { total += f64(abs(a[i] - b[i])) }
	return total / f64(max(len(a), 1))
}

type_checks :: proc() {
	for example in EXAMPLES {
		for check in TYPE_CHECKS {
			command: [dynamic]string
			append(&command, "odin", "check", fmt.aprintf("examples_3d/%s", example), "-vet", "-strict-style")
			append(&command, ..check.flags)
			code, lines := run(command[:])

			if code == 0 {
				check_ok("%s: %s", example, check.label)
			} else {
				check_fail("%s: %s", example, check.label)
				show_lines(lines, 6)
			}
		}
	}
}

unit_tests :: proc(out_dir: string) {
	code, lines := run({
		"odin", "test", "tests/render3d", "-define:KARL2D_RENDER_BACKEND=nil", "-define:KARL2D_AUDIO_BACKEND=nil",
		fmt.aprintf("-out:%s/test_render3d.exe", out_dir),
	})
	count: string

	for line in lines {
		if found := test_summary_count(line); found != "" { count = found }
	}

	if code == 0 && count != "" {
		check_ok("tests/render3d (%s tests)", count)
	} else {
		check_fail("tests/render3d")
		show_lines(lines, 6)
	}
}

load_png :: proc(path: string) -> ^png.Image {
	image, error := png.load_from_file(path, {.alpha_add_if_missing})
	return image if error == nil else nil
}

// The same frozen frame rendered by the D3D11 and the GL backend must look the same (edge pixels may differ a little)
compare_backends :: proc(example, out_dir: string) -> (reference_path: string, ok: bool) {
	names := [2]string{"d3d11", "gl"}
	paths: [2]string

	for name, i in names {
		exe := fmt.aprintf("%s/r3d_%s_%s.exe", out_dir, example, name)
		paths[i] = fmt.aprintf("%s/r3d_%s_%s.png", out_dir, example, name)
		os.remove(paths[i])
		arguments: [dynamic]string
		append(&arguments, "odin", "build", fmt.aprintf("examples_3d/%s", example), fmt.aprintf("-out:%s", exe), fmt.aprintf("-define:R3D_SCREENSHOT=%s", paths[i]), "-define:R3D_FRAMES=30")

		if name == "gl" {
			append(&arguments, "-define:KARL2D_RENDER_BACKEND=gl")
		}

		code, lines := run(arguments[:])

		if code != 0 {
			check_fail("%s: building the %s example", example, name)
			show_lines(lines, 4)
			return paths[0], false
		}

		exit_code := run_with_timeout({exe}, 60, out_dir)

		if exit_code != 0 || !os.exists(paths[i]) {
			check_fail("%s: the %s example did not write its screenshot (exit %d)", example, name, exit_code)
			return paths[0], false
		}
	}

	a, b := load_png(paths[0]), load_png(paths[1])

	if a == nil || b == nil {
		check_fail("%s: cannot read the screenshots", example)
		return paths[0], false
	}

	if a.width != b.width || a.height != b.height || a.channels != 4 || b.channels != 4 {
		check_fail("%s: the screenshots differ in size or format", example)
		return paths[0], false
	}

	mean, far_share := image_difference(a.pixels[:], b.pixels[:], 24)

	if mean < 0.5 && far_share < 0.005 {
		check_ok("%s: d3d11 and gl render the same frame (mean difference %.2f of 255, %.2f%% of pixels differ by more than 24)", example, mean, far_share * 100)
		return paths[0], true
	}

	check_fail("%s: d3d11 and gl differ (mean difference %.2f of 255, %.2f%% of pixels differ by more than 24; images in %s)", example, mean, far_share * 100, out_dir)
	return paths[0], false
}

// The html5 build (WebGL2) in a browser must look like the D3D11 frame at a coarse scale
compare_web :: proc(example, out_dir, reference_path, karl2d_root: string) {
	browser: string

	for path in BROWSER_PATHS {
		if os.exists(path) {
			browser = path
			break
		}
	}

	if browser == "" {
		check_skip("%s: html5 (no Edge or Chrome found)", example)
		return
	}

	web_png := fmt.aprintf("%s/r3d_%s_web.png", out_dir, example)
	os.remove(web_png)

	code, lines := run({"odin", "run", "build_web", "--", fmt.aprintf("examples_3d/%s", example), "-define:R3D_SCREENSHOT=web", "-define:R3D_FRAMES=30"})

	if code != 0 {
		check_fail("%s: html5 build", example)
		show_lines(lines, 4)
		return
	}

	page := fmt.aprintf("file:///%s/examples_3d/%s/bin/web/index.html", karl2d_root, example)
	exit_code := run_with_timeout({
		browser, "--headless=new", "--allow-file-access-from-files", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
		"--ignore-gpu-blocklist", "--window-size=1280,720", "--virtual-time-budget=15000",
		fmt.aprintf("--user-data-dir=%s/browser_profile", out_dir),
		fmt.aprintf("--screenshot=%s", web_png), page,
	}, 90)

	if exit_code != 0 || !os.exists(web_png) {
		check_fail("%s: html5 capture (browser exit %d, no screenshot)", example, exit_code)
		return
	}

	reference, captured := load_png(reference_path), load_png(web_png)

	if reference == nil || captured == nil {
		check_fail("%s: html5 comparison (cannot read the screenshots)", example)
		return
	}

	a := grid_means(reference.pixels[:], reference.width, reference.height, 48, 27)
	b := grid_means(captured.pixels[:], captured.width, captured.height, 48, 27)
	difference := mean_grid_difference(a, b)

	if difference < 3 {
		check_ok("%s: html5 (WebGL2 in a browser) matches d3d11 (mean difference %.2f of 255 per 48x27 grid cell)", example, difference)
	} else {
		check_fail("%s: html5 differs from d3d11 (mean difference %.2f of 255 per grid cell; images in %s)", example, difference, out_dir)
	}
}

main :: proc() {
	quick, no_web: bool

	for argument in os.args[1:] {
		switch argument {
		case "--quick": quick = true
		case "--no-web": no_web = true
		case:
			fmt.printfln("unknown option %s (usage: odin run tools/render3d_check -- [--quick] [--no-web])", argument)
			os.exit(2)
		}
	}

	if !os.exists("render3d.odin") || !os.is_directory("tools/render3d_check") {
		fmt.println("run this from the root of the karl2d fork (the folder with render3d.odin)")
		os.exit(2)
	}

	root, root_error := filepath.abs(".", context.allocator)
	out_dir, out_error := filepath.abs("tools/render3d_check/out", context.allocator)

	if root_error != nil || out_error != nil {
		fmt.println("cannot resolve the folders of the fork")
		os.exit(2)
	}

	os.make_directory_all(out_dir)
	root, _ = strings.replace_all(root, "\\", "/")
	out_dir, _ = strings.replace_all(out_dir, "\\", "/")

	type_checks()
	unit_tests(out_dir)

	when ODIN_OS == .Windows {
		if !quick {
			for example in EXAMPLES {
				reference, ok := compare_backends(example, out_dir)

				if ok && !no_web {
					compare_web(example, out_dir, reference, root)
				}
			}
		}
	}

	fmt.printfln("karl2d 3D layer: %d problem(s)", failures)
	os.exit(1 if failures > 0 else 0)
}

// --- Tests ---

@(test)
test_image_difference :: proc(t: ^testing.T) {
	same := []u8{10, 20, 30, 255, 40, 50, 60, 255}
	mean, far := image_difference(same, same, 8)
	testing.expect(t, mean == 0 && far == 0)

	other := []u8{10, 20, 30, 255, 40, 50, 100, 255}
	mean, far = image_difference(same, other, 8)
	testing.expect_value(t, mean, 40.0 / 8)
	testing.expect_value(t, far, 0.5)
}

@(test)
test_grid_means :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	pixels := []u8{
		10, 0, 0, 255,   10, 0, 0, 255,   200, 0, 0, 255,   200, 0, 0, 255,
		10, 0, 0, 255,   10, 0, 0, 255,   200, 0, 0, 255,   200, 0, 0, 255,
	}
	means := grid_means(pixels, 4, 2, 2, 1)
	testing.expect_value(t, means[0], 10)
	testing.expect_value(t, means[3], 200)
	testing.expect_value(t, mean_grid_difference(means, means), 0)
}

@(test)
test_summary_line :: proc(t: ^testing.T) {
	testing.expect_value(t, test_summary_count("Finished 29 tests in 1.17s. All tests were successful."), "29")
	testing.expect_value(t, test_summary_count("Finished 1 test in 42ms. The test was successful."), "1")
	testing.expect_value(t, test_summary_count("Finished tests"), "")
	testing.expect_value(t, test_summary_count("something else"), "")
}
