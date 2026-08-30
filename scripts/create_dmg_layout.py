#!/usr/bin/env python3
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias, Bookmark


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: create_dmg_layout.py MOUNT_POINT")

    mount_point = Path(sys.argv[1])
    background = mount_point / ".background.png"
    store_path = mount_point / ".DS_Store"

    window_settings = {
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "SidebarWidth": 180,
        "WindowBounds": "{{200, 120}, {660, 420}}",
    }
    icon_settings = {
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
        "backgroundType": 2,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": 112.0,
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": False,
        "showItemInfo": False,
        "textSize": 14.0,
        "viewOptionsVersion": 1,
    }

    with DSStore.open(str(store_path), "w+") as store:
        store["."]["bwsp"] = window_settings
        store["."]["icvl"] = ("type", "icnv")
        store["."]["icvp"] = icon_settings
        store["."]["pBBk"] = Bookmark.for_file(str(background))
        store["."]["vSrn"] = ("long", 1)
        store["Applications"]["Iloc"] = (495, 205)
        store["McSpeechface.app"]["Iloc"] = (165, 205)


if __name__ == "__main__":
    main()
