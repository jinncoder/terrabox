#!/bin/bash

entries="🚪 Logout
⏸ Suspend
🔄 Reboot
⏻ Shutdown"

selected=$(printf '%s\n' "$entries" | fuzzel --dmenu)

[ -z "$selected" ] && exit 0

action=$(echo "$selected" | awk '{print tolower($2)}')

confirm() {
  choice=$(printf "No\nYes" | fuzzel --dmenu --prompt="Confirm $1?")
  [ "$choice" = "Yes" ]
}

case $action in
  logout)
    swaymsg exit
    ;;

  suspend)
    systemctl suspend
    ;;

  reboot)
    if confirm "reboot"; then
      systemctl reboot
    fi
    ;;

  shutdown)
    if confirm "shutdown"; then
      systemctl poweroff -i
    fi
    ;;
esac
