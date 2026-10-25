import os

application = defines["app"]
appname = os.path.basename(application)
volume_name = "X Ode"
format = "ULFO"
filesystem = "APFS"
files = [application, defines["install_note"], defines["release_notes"]]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
icon_locations = {
    appname: (160, 190),
    "Applications": (480, 190),
    "INSTALL.txt": (160, 355),
    "RELEASE-NOTES.txt": (480, 355),
}
background = defines["background"]
window_rect = ((100, 100), (640, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 14
