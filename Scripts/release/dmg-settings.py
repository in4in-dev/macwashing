# dmgbuild settings for the release DMG (build-dmg.sh): the app on the left, the Applications link on the right,
# the arrow between them drawn in the background (dmg/background.tiff, 1x + 2x; made from dmg/background.svg by dmg/render-background.sh).
# dmgbuild writes the window layout (.DS_Store) itself: no AppleScript to Finder, the same result on every build.
#
# Defines passed by build-dmg.sh (-D): app (path of MacWashing.app), background (.tiff), icon (volume .icns).
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

# Window: 640 × 420 points of content; icons centred on the background's two spots.
window_rect = ((200, 140), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (170, 200),
    "Applications": (470, 200),
}
