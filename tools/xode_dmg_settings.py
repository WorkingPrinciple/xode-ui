import os

application = defines["app"]
appname = os.path.basename(application)
volume_name = "X Ode"
format = "ULFO"
filesystem = "APFS"
files = [application, defines["install_note"], defines["release_notes"],
         defines["resource_inventory"]]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
icon_locations = {
    appname: (165, 190),
    "Applications": (495, 190),
    "INSTALL.txt": (165, 330),
    "RELEASE-NOTES.txt": (495, 330),
    "RESOURCE-INVENTORY.json": (330, 330),
}
background = defines["background"]
window_rect = ((100, 100), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 14
