/* gltri.c — minimal OpenGL SDL2 program to smoke-test the `terminal` video
   driver's headless-GL path. Draws an immediate-mode (fixed-function) Gouraud
   triangle for a few seconds. Build + run:

     cc gltri.c $(PKG_CONFIG_PATH=../install/lib/pkgconfig pkg-config --cflags --libs sdl2) -o /tmp/gltri
     SDL_VIDEODRIVER=terminal /tmp/gltri        # inside kitty / Ghostty / Ubiquitty
*/
#define SDL_MAIN_HANDLED
#define GL_SILENCE_DEPRECATION
#include <SDL.h>
#include <OpenGL/gl.h>   /* on Linux this would be <GL/gl.h> (the GL path is macOS-only for now) */
#include <stdio.h>

int main(void)
{
    SDL_SetMainReady();
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    fprintf(stderr, "video driver = %s\n", SDL_GetCurrentVideoDriver());

    SDL_Window *w = SDL_CreateWindow("gltri", 0, 0, 320, 240, SDL_WINDOW_OPENGL);
    if (!w) { fprintf(stderr, "CreateWindow: %s\n", SDL_GetError()); return 1; }
    SDL_GLContext c = SDL_GL_CreateContext(w);
    if (!c) { fprintf(stderr, "GL_CreateContext: %s\n", SDL_GetError()); return 1; }

    fprintf(stderr, "GL_RENDERER = %s\n", (const char *)glGetString(GL_RENDERER));

    for (int frame = 0; frame < 120; frame++) {
        SDL_Event e;
        while (SDL_PollEvent(&e))
            if (e.type == SDL_QUIT) goto done;
        glViewport(0, 0, 320, 240);
        glClearColor(0.1f, 0.2f, 0.5f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glBegin(GL_TRIANGLES);
            glColor3f(1, 0, 0); glVertex2f(-0.6f, -0.6f);
            glColor3f(0, 1, 0); glVertex2f( 0.6f, -0.6f);
            glColor3f(0, 0, 1); glVertex2f( 0.0f,  0.7f);
        glEnd();
        SDL_GL_SwapWindow(w);
        SDL_Delay(33);
    }
done:
    SDL_GL_DeleteContext(c);
    SDL_DestroyWindow(w);
    SDL_Quit();
    return 0;
}
