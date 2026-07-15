#!/usr/bin/env bash
# build.sh — fetch a pinned upstream SDL2, graft in the `terminal` video driver,
# and build a static libSDL2 that renders any SDL2 program into a Kitty-graphics
# terminal via SDL_VIDEODRIVER=terminal.
#
# SDL video drivers are compiled INTO libSDL2 (they are not loadable plugins), so
# there is no way to ship this as a drop-in dylib — we build our own SDL. This
# script is the whole story: it never modifies your system SDL.
#
#   ./build.sh                 # build into ./install
#   SDL_TAG=release-2.32.10 ./build.sh
#   ./build.sh --prefix /opt/sdl-terminal
#
# Output: $PREFIX/{lib/libSDL2.a, include/SDL2, lib/pkgconfig/sdl2.pc}.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDL_TAG="${SDL_TAG:-release-2.32.10}"   # pinned; the driver targets this SDL2 API
PREFIX="$HERE/install"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

WORK="$HERE/.build"
SDL="$WORK/SDL"

echo ">> SDL $SDL_TAG -> $PREFIX"

# 1. Fetch pinned upstream SDL2 (shallow).
if [ ! -d "$SDL/.git" ]; then
    rm -rf "$WORK"; mkdir -p "$WORK"
    git clone --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$SDL"
else
    echo ">> reusing existing checkout ($SDL)"
fi

# 2. Graft the driver in. It lives under src/video/dummy/ on purpose: SDL's build
#    already globs that directory, so no configure/CMake regeneration is needed,
#    and it is gated by the same SDL_VIDEO_DRIVER_DUMMY that is always on.
cp "$HERE/src/SDL_terminalvideo.c" "$SDL/src/video/dummy/SDL_terminalvideo.c"

# 3. Register the driver in SDL's bootstrap list. Two idempotent edits, keyed on
#    the DUMMY driver's own markers so they survive minor upstream line drift.
SYS="$SDL/src/video/SDL_sysvideo.h"
if ! grep -q 'TERMINAL_bootstrap' "$SYS"; then
    # insert the extern just before the DUMMY one
    perl -0pi -e 's/(extern VideoBootStrap DUMMY_bootstrap;)/extern VideoBootStrap TERMINAL_bootstrap;\n$1/' "$SYS"
fi
VID="$SDL/src/video/SDL_video.c"
if ! grep -q 'TERMINAL_bootstrap' "$VID"; then
    # list TERMINAL before DUMMY so an explicit SDL_VIDEODRIVER=terminal wins and
    # the default probe order is unchanged for everyone else
    perl -0pi -e 's/(\n[ \t]*)(&DUMMY_bootstrap,)/${1}&TERMINAL_bootstrap,${1}$2/' "$VID"
fi
grep -q 'TERMINAL_bootstrap' "$SYS" && grep -q 'TERMINAL_bootstrap' "$VID" \
    || { echo "!! failed to register TERMINAL_bootstrap (upstream layout changed?)" >&2; exit 1; }

# 4. Configure + build a static lib. Mirrors the flags DOSBox-X uses; on macOS the
#    Cocoa GL backend is what the driver's headless-GL path (CGL) rides on, so we
#    do NOT disable OpenGL.
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
BUILD="$WORK/out"; rm -rf "$BUILD"; mkdir -p "$BUILD"
chmod +x "$SDL/configure"

CONFOPTS="--enable-static --disable-shared --prefix=$PREFIX"
case "$(uname -s)" in
    Darwin) CONFOPTS="$CONFOPTS --disable-video-x11" ;;
    Linux)  : ;;
    *)      CONFOPTS="$CONFOPTS --disable-video-wayland --disable-libudev" ;;
esac

( cd "$BUILD" && "$SDL/configure" $CONFOPTS && make -j"$JOBS" && make install )

# 5. macOS: the headless-GL path calls CGL/GL, so consumers must link
#    OpenGL.framework. Make the vendored pkg-config self-describing (configure's
#    generated .pc omits it).
PC="$PREFIX/lib/pkgconfig/sdl2.pc"
if [ "$(uname -s)" = "Darwin" ] && [ -f "$PC" ] && ! grep -q 'framework,OpenGL' "$PC"; then
    perl -0pi -e 's/^(Libs: -L\$\{libdir\})/$1  -Wl,-framework,OpenGL/m' "$PC"
fi

echo
echo ">> done. libSDL2 with the 'terminal' driver is in: $PREFIX"
echo ">>   headers:    $PREFIX/include/SDL2"
echo ">>   static lib: $PREFIX/lib/libSDL2.a"
echo ">>   pkg-config: PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --cflags --libs sdl2"
echo ">> Try:  cc examples/gltri.c \$(PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --cflags --libs sdl2) -o /tmp/gltri"
echo ">>       SDL_VIDEODRIVER=terminal /tmp/gltri   # run inside kitty/Ghostty/Ubiquitty"
