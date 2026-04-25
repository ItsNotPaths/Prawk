#define UI_IMPLEMENTATION
#include "luigi.h"

UIWindow **prawk_ui_windows(void)     { return &ui.windows; }
UITheme   *prawk_ui_theme(void)       { return &ui.theme; }
UIFont   **prawk_ui_active_font(void) { return &ui.activeFont; }
