"""Loaded by dmgbuild; paths are supplied by the packaging script."""

import os

application = defines["app"]
files = [application]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = "builtin-arrow"
window_rect = ((100, 100), (640, 280))
icon_locations = {os.path.basename(application): (140, 120), "Applications": (500, 120)}
icon_size = 96
text_size = 14
default_view = "icon-view"
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
