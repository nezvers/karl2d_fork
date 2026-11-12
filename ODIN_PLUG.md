# karl2d for odin_plug

This branch (`odin_plug` of https://github.com/nezvers/karl2d_fork) is upstream Karl2D
(https://github.com/karl-zylinski/karl2d) plus the changes audio plugin editors need. Every change is its own commit
and every changed line is marked with `// ODIN_PLUG:` so rebasing on upstream stays easy.

Upstream base: `684e1f8` (Replace stb_rect_pack and stb_truetype with Odin ports that do the minimal stuff Karl2d needs)

## Changes

| Commit | Files | What and why |
|---|---|---|
| embed into a parent window | `karl2d.odin` (`Init_Options.parent_window`), `platform_windows.odin` (`windows_init_embedded`, `windows_embedded_class_name`, `Windows_State.embedded/parent`, `windows_set_screen_size`, `windows_set_window_mode`, `WM_DESTROY`), `platform_bindings/windows/win32_extra` (`GetModuleHandleExW`) | Plugin editors are child windows inside the host's window. The window class is registered per DLL under a unique name (two plugins built with Karl2D would otherwise share one window procedure). DPI awareness and `PostQuitMessage` are process wide and belong to the host. Window modes do not apply to a child window. |
| allow several instances | `karl2d.odin` (`init`, `get_internal_state`) | A host opens one editor per plugin instance. `init` makes the new `State` current instead of asserting; editors switch with `set_internal_state` before drawing and can restore with `get_internal_state`. Only `s` and `frame_allocator` are package globals, `set_internal_state` already swaps both. |
| pump only own messages | `platform_windows.odin` (`windows_get_events`) | The host runs the message loop of the UI thread. Embedded windows peek only their own messages, otherwise Karl2D would dispatch the host's messages. |

Not code changes, how odin_plug uses Karl2D:
- Host driven frames: Karl2D never owns a loop, the editor calls `update()`/`present()` from a host timer
  (CLAP `timer-support`, VST3 `IRunLoop`/`WM_TIMER`). Use `Init_Options.disable_vsync = true` for embedded editors,
  vsync would make every open editor wait for the display in turn.
- No audio: build plugins with `-define:KARL2D_AUDIO_BACKEND=nil`, the plugin host owns audio.
- Not done yet: Linux/macOS embedding (X11 reparenting, NSView child), they ignore `parent_window` for now.

## Rebasing on upstream

```
cd karl2d
git fetch upstream
git rebase upstream/master          # conflicts only appear in lines marked // ODIN_PLUG:
odin check examples/basics -vet
git push --force-with-lease origin odin_plug
cd ..
git add karl2d                      # odin_plug records the new submodule commit
```
Update "Upstream base" above after a rebase. Keep `master` of the fork equal to upstream (`git push origin upstream/master:master`).
