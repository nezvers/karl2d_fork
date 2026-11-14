# 3D layer for karl2d (branch `render3d`)

A stylized 3D forward renderer on top of karl2d, living entirely in NEW files so rebasing on upstream stays cheap. Branch
`render3d` is `odin_plug` (upstream + the embed commits, see ODIN_PLUG.md) plus the commits listed here. Every commit subject starts
with `RENDER3D:`. No upstream-owned file is edited: `git diff --stat odin_plug..render3d` must list only the files below.

## Files

| File | What |
|---|---|
| `render3d_types.odin` | `R3d_Vertex` (48 bytes: position, normal, uv, colour, joints, weights, outline normal), `R3d_Instance` (8 float4 = 128 bytes), `R3d_Camera`, `R3d_Environment`, `R3d_Material`, `R3d_Globals`/`R3d_Material_Constants` (GPU layouts, size asserted) |
| `render3d_math.odin` | reverse-Z perspective/ortho for either backend clip range, look-at, TRS, instance helpers |
| `render3d_mesh_builders.odin` | cube, plane, sphere, cylinder with smoothed outline normals |
| `render3d.odin` | public API: `r3d_init/shutdown`, `r3d_mesh_create*`, `r3d_begin_scene/end_scene`, `r3d_draw`, `r3d_draw_one`, `r3d_read_pixels`, stats |
| `render3d_lights.odin` | clustered lights: 16x9x24 view clusters (tiles in x/y, logarithmic depth slices), `r3d_bin_lights` lists the lights per cluster (conservative: sphere bounds projected through the view-projection, camera-plane overlap covers the whole tile range), `r3d_pack_lights`; three RGBA32F data textures (lights, cluster offset/count, packed indices) read by the pixel shader; up to 1,024 point/spot lights, 96 per cluster |
| `render3d_tween.odin` | per-instance tweens: `r3d_instance_tween` writes (from, to, start, duration, easing, effect, loop, phase) into the instance once; the shader evaluates it from the global time (effects: scale, fade, rise, flash); CPU mirror of the easing formulas |
| `render3d_cull.odin` | frustum from the view-projection (both clip ranges), sphere tests, `r3d_cull_instances` into a caller slice with an optional distance limit |
| `render3d_backend_interface.odin` | `R3d_Backend_Interface`: mesh, begin/end pass, instanced draw, read_pixels |
| `render3d_backend_chooser.odin` | picks the 3D backend from `RENDER_BACKEND_NAME` (backends without a 3D implementation use the nil one) |
| `render3d_backend_d3d11.odin` + `render3d_shaders/r3d_mesh_d3d11.hlsl` | D3D11: own shaders, retained vertex/index buffers, instance data texture bound to the VERTEX stage, own rasterizer/depth states |
| `render3d_backend_gl.odin` + `render3d_shaders/r3d_mesh.glsl` | desktop GL: the same design, uniform blocks, VAO per mesh, `glDrawElementsInstanced`; restores the GL states the karl2d GL backend assumes |
| `render3d_backend_webgl.odin` | WebGL2 (html5): same source and shader file (GLSL ES 3.00 header), WebGL binding types |
| `render3d_backend_nil.odin` | headless: counts passes, draws, instances, triangles |
| `render3d_internal.odin` | the one place that asks karl2d for its state |
| `examples_3d/lights` | 256 coloured point lights and 4 spot lights, one forward pass; HUD shows cluster entries |
| `examples_3d/foliage_wind` | 8,100 trees in ONE draw call: wind sway in the vertex shader (material `wind_weight`/`wind_height`, globals wind block), grow-in tweens on the GPU, CPU culling; same screenshot mode as toon_scene |
| `examples_3d/toon_scene` | toon + rim + outline + fog, 64 cubes in one draw call; `-define:R3D_SCREENSHOT=out.png -define:R3D_FRAMES=30` writes a PNG and exits |
| `tests/render3d` | winding, reverse-Z for both clip ranges, look-at, instance rows, outline normals (17 tests, `odin test tests/render3d -define:KARL2D_RENDER_BACKEND=nil -define:KARL2D_AUDIO_BACKEND=nil`) |

## Upstream symbols the layer uses (what a rebase can break)

All reached through `get_internal_state()` (ODIN_PLUG hook) or because the layer is in `package karl2d`:
`State.{depth_test, rb, rb_state, textures, current_render_target, current_render_target_width/height, draw_call_changes}`,
`Render_Backend_Interface.{get_depth_clip_range, flip_render_textures}`, `Texture_Object.rb_texture`, `draw_current_batch`,
`DRAW_CALL_CHANGE_ALL`, `get_screen_width/height`, `get_time`, `get_frame_time`, `RENDER_BACKEND_NAME`, `Handle`, `Color`, `Vec2/3`, `Mat4`,
`Render_Backend_Texture`, `Render_Target_Handle`, `RENDER_TARGET_NONE`, `TEXTURE_NONE`.
D3D11 backend only: `D3D11_State.{device, device_context, framebuffer, framebuffer_view, depth_buffer_view, render_targets, textures, anti_alias, width, height}`,
`D3D11_Render_Target.{render_target_view, depth_buffer_view, width, height}`, `D3D11_Texture.view`, `d3d11_check`, `d3d11_log_messages`.

## Using it

- `Init_Options.depth_test = true` is required (the layer shares karl2d's depth buffer, which uses GREATER_EQUAL with a clear of 0; the 3D projection is reversed-Z to match).
- Frame: `k2.clear(...)`, `r3d_begin_scene(camera, environment)`, `r3d_draw(...)`, `r3d_end_scene()`, then 2D with `k2.set_z(1)` so the HUD is in front of the 3D depth values.
- `r3d_begin_scene` flushes the 2D batch first; `r3d_end_scene` unbinds what the layer bound and karl2d re-sets all of its own state on the next 2D draw.
- One draw call per mesh+material for any number of instances (capacity set by `r3d_init(max_instances)`, default 16384).

## Status (milestones of the plan)

M0, M1, M2 and M3 done on D3D11, GL and WebGL2 (M2: global wind block, per-instance tween parameters evaluated on the GPU, `R3d_Environment.time_override` for deterministic frames, instance culling, foliage example; M3: clustered point/spot lights with toon banding per light, `r3d_begin_scene(camera, environment, lights)`, `r3d_light_stats`). M1: toon bands (or ramp texture), rim light, specular blob, hemisphere ambient, fog, inverted-hull outline with constant screen width, albedo texture / vertex colour / cutout, instancing through a vertex-fetched data texture.
Verified: the same deterministic frame of `toon_scene` rendered by D3D11 and by GL (both examples) differs by a mean of 0.00 of 255 (`odin run tools/dev -- karl2d` from odin_plug builds both, runs them and compares), and the html5 build rendered by headless Edge/Chrome matches D3D11 at a coarse 48x27 grid (mean 0.93 of 255 for toon_scene, 0.18 for foliage_wind, 0.30 for lights).
Not done yet: shadows, runtime AO, GPU skinning, post-effect examples, more examples.

## Known facts about this branch

- `tools/api_verifier` already reports `karl2d.doc.odin` as out of date on `odin_plug` (the ODIN_PLUG commits added `get_internal_state` and `parent_window`); the 3D layer adds no lines to `karl2d.odin`.
- `odin check` of Linux targets needs the compiled stb libraries (`vendor/stb/src/build_stb.sh`), for upstream examples as well.

## Rebasing

```
cd karl2d
git fetch upstream
git rebase upstream/master          # odin_plug commits first
git switch odin_plug && git rebase upstream/master
git switch render3d && git rebase odin_plug
odin check examples_3d/toon_scene -vet -strict-style
odin test tests/render3d -define:KARL2D_RENDER_BACKEND=nil -define:KARL2D_AUDIO_BACKEND=nil
```
Compile errors after a rebase are expected only in `render3d_internal.odin` and the `render3d_backend_*.odin` files.
