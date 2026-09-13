# dmgbuild settings for the Kylmora installer disk image.
#   dmgbuild -s Tools/dmg-settings.py "Kylmora" build/Kylmora.dmg
# Run from the repository root, after `make bundle` has produced the app.
import os.path

app = defines.get("app", "build/Kylmora.app")  # noqa: F821 (dmgbuild injects `defines`)
appname = os.path.basename(app)

# Contents: the app plus a shortcut to /Applications to drag it onto.
files = [app]
symlinks = {"Applications": "/Applications"}

# Compressed, read-only image.
format = "UDZO"

# A fixed, compact window with a clean chrome and the arrow background.
background = "Resources/dmg-background.tiff"
window_rect = ((240, 200), (620, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Icon placement — centres kept in sync with Tools/make-dmg-background.py.
icon_size = 128
text_size = 13
icon_locations = {
    appname: (165, 200),
    "Applications": (455, 200),
}
