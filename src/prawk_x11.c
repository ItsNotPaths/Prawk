// Tiny helper so prawk can push X11 keyboard focus to a luigi popup menu
// without patching vendored luiginim bindings.
// Includes luigi.h for the UIWindow typedef only (UI_IMPLEMENTATION is
// passed globally by luiginim; undef it so we don't double-instantiate).
#undef UI_IMPLEMENTATION
#include <X11/Xlib.h>
#include "../vendor/luigi/luigi.h"

static Display *dpy = NULL;

void prawk_x_focus_menu(UIWindow *win) {
    if (!win) return;
    if (!dpy) dpy = XOpenDisplay(NULL);
    if (!dpy) return;
    XSetInputFocus(dpy, win->window, RevertToParent, CurrentTime);
    XFlush(dpy);
}
