#!/bin/bash

grep -E '^ *bindsym' ~/.config/sway/config | \
sed -e 's/^ *bindsym *//' | \
fuzzel --lines=30 --width=90 --dmenu --prompt="⚡ Keybinds: "
