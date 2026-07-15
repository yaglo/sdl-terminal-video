# sdl-terminal-video

An SDL2 **`terminal` video driver**: it renders any SDL2 program into a text
terminal that speaks the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
— no window, no X11, no Wayland. Select it with `SDL_VIDEODRIVER=terminal`.

It handles both SDL rendering paths:

- **Software framebuffer** (`SDL_GetWindowSurface`, `SDL_Renderer` software) — the
  window's pixels are encoded and streamed to the terminal each frame.
- **OpenGL** (`SDL_GL_CreateContext`) — on macOS a headless CGL context renders
  into an FBO, which is read back and streamed the same way. This is what lets
  GL-only games (e.g. ioquake3) run in a terminal.

Mouse, keyboard, resize, relative-mouse "mouselook" (Kitty/Ubiquitty pointer
lock), shared-memory/zlib frame transports, and 4:3 aspect correction are all
supported and auto-detected per terminal. It originated in
terminal-dosbox-x (running DOSBox-X in a terminal) and is
a general-purpose driver — DOSBox-X is just one SDL2 app among many.

This is an **overlay**, not a fork: `build.sh` fetches a pinned upstream SDL2,
grafts one source file plus a two-line registration, and builds a static
`libSDL2`. Your system SDL is never touched.

## Requirements

- A Kitty-graphics terminal: **[Ubiquitty](https://github.com/yaglo/ubiquitty), kitty, or Ghostty**.
- To build SDL: a C toolchain, `git`, `make`, and autotools (what upstream SDL2
  needs). macOS or Linux.
- **OpenGL support is macOS-only today** (headless CGL + FBO). The framebuffer
  path is cross-platform; a Linux GL backend (EGL surfaceless) is future work.

## Quick start

```sh
./build.sh                       # fetches SDL 2.32.10, builds ./install/libSDL2.a
PKG=install/lib/pkgconfig

# a tiny GL demo (spinning-free triangle) rendered in your terminal:
cc examples/gltri.c $(PKG_CONFIG_PATH=$PKG pkg-config --cflags --libs sdl2) -o /tmp/gltri
SDL_VIDEODRIVER=terminal /tmp/gltri     # run inside kitty / Ghostty / Ubiquitty
```

---

## Tutorial: enable it for an existing SDL2 game

The driver is transparent to SDL2 apps — the work is **building your game against
this SDL** instead of the system one, then selecting the driver at runtime.

### 1. Build the driver's SDL

```sh
./build.sh --prefix /opt/sdl-terminal
```

You now have `/opt/sdl-terminal/{lib/libSDL2.a, include/SDL2, lib/pkgconfig/sdl2.pc}`.

### 2. Point your game's build at it

**Static linking is strongly recommended** so a system `libSDL2.dylib`/`.so` can't
shadow this one at runtime.

- **pkg-config / autotools game:**
  ```sh
  export PKG_CONFIG_PATH=/opt/sdl-terminal/lib/pkgconfig
  ./configure   # or: SDL2_CFLAGS/SDL2_LIBS from `pkg-config --cflags --libs sdl2`
  ```
- **CMake game:** disable any bundled/system SDL and hand it this prefix:
  ```sh
  cmake -S . -B build -DCMAKE_PREFIX_PATH=/opt/sdl-terminal \
        -DSDL2_DIR=/opt/sdl-terminal/lib/cmake/SDL2   # if the game uses find_package(SDL2)
  ```
  If the game uses pkg-config inside CMake, set `PKG_CONFIG_PATH` as above.

On **macOS**, GL games must link `-framework OpenGL`; `build.sh` already adds it to
the generated `sdl2.pc`, so pkg-config consumers get it automatically.

### 3. Run it in a terminal

```sh
SDL_VIDEODRIVER=terminal ./yourgame >/tmp/game.log 2>&1
```

Redirect the game's **stdout/stderr to a file** — the driver writes the image
stream to `/dev/tty`, and log text on the same tty would corrupt it.

### Worked example: ioquake3

A full GL game, start to finish (assumes free OpenArena data in `~/oa/baseoa`):

```sh
git clone --depth 1 https://github.com/ioquake/ioq3 && cd ioq3
```

Teach ioq3's SDL lookup to consume this driver's pkg-config. In
`cmake/libraries/sdl.cmake`, before its `find_package(SDL2)` fallback, add:

```cmake
find_package(PkgConfig REQUIRED)
set(ENV{PKG_CONFIG_PATH} "/opt/sdl-terminal/lib/pkgconfig")
pkg_check_modules(TSDL REQUIRED sdl2)
set(SDL2_INCLUDE_DIRS ${TSDL_STATIC_INCLUDE_DIRS})
set(SDL2_LIBRARIES /opt/sdl-terminal/lib/libSDL2main.a ${TSDL_STATIC_LDFLAGS} "-Wl,-framework,OpenGL")
```

Then configure and build:

```sh
cmake -S . -B build \
  -DUSE_INTERNAL_SDL=OFF \
  -DUSE_RENDERER_DLOPEN=OFF \        # static SDL must link once, not into a dlopen'd renderer
  -DBUILD_RENDERER_GL1=ON \
  -DBUILD_RENDERER_GL2=OFF \         # GL1 draws to the default framebuffer (our FBO); see caveats
  -DBUILD_MACOS_APP=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64    # match the arch of your built libSDL2
cmake --build build -j

SDL_VIDEODRIVER=terminal build/Release/ioquake3 \
  +set com_basegame baseoa +set com_standalone 1 \
  +set fs_basepath ~/oa \
  +set r_fullscreen 0 +set r_mode -1 +set r_customwidth 640 +set r_customheight 480 \
  >/tmp/ioq3.log 2>&1
```

## Caveats & gotchas

- **Run windowed, not fullscreen.** Fullscreen sizes the SDL window to the
  driver's registered display mode (default 640×480) while the game keeps its own
  viewport, giving a partial frame. Use `r_fullscreen 0` (or your game's
  equivalent) and set the window size explicitly.
- **GL renderer choice.** The headless context has no usable default framebuffer,
  so we bind an FBO and let the app render into it. That is transparent for apps
  that draw to the default framebuffer (ioquake3's fixed-function **GL1**). Apps
  that rebind framebuffer 0 mid-pipeline (ioquake3's **GL2**) will need a
  `glBindFramebuffer(…,0)` remap — future work.
- **Static SDL + dlopen.** If your engine dlopens a module that also uses SDL
  (ioq3's renderer), link SDL once (turn dlopen off) so there aren't two copies of
  SDL's global state.
- **OpenGL is macOS-only** for now (CGL). GL apps on Linux need an EGL-surfaceless
  backend (not yet written). 2D / software-surface apps work everywhere.

## How it works

`src/SDL_terminalvideo.c` is a self-contained SDL2 video device:

- `CreateWindowFramebuffer`/`UpdateWindowFramebuffer` → encode the surface to a
  Kitty graphics frame (base64, or shared-memory / file transport when the
  terminal supports it; optional zlib) and write it to the tty.
- On macOS, `GL_CreateContext` builds a headless CGL **legacy-2.1** context (so
  fixed-function GL1 and GL2 both work) backed by an **FBO** (color + depth24/
  stencil8). `GL_SwapWindow` does `glReadPixels` → the same Kitty encoder.
- Terminal input (Kitty keyboard protocol, SGR-pixel mouse, DECRQM capability
  probes, pointer-lock break-out) is decoded back into SDL events.

Everything is gated on `SDL_VIDEO_DRIVER_DUMMY` (always on) and selected only when
`SDL_VIDEODRIVER=terminal`, so it never changes behaviour for other drivers.

See the header of `src/SDL_terminalvideo.c` for the full list of `SDL_TERMINAL_*`
environment variables (aspect, transport, fullscreen, zlib, debug…).

## License

`src/SDL_terminalvideo.c` is licensed under the [zlib license](LICENSE), the same
as SDL itself, so it can be vendored alongside — or eventually upstreamed into —
SDL. The build script and docs are under the same terms.
