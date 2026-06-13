#!/usr/bin/env bash
# Prompt for a new workspace name using fuzzel
new_name=$(fuzzel --dmenu --prompt "Rename workspace to: ")

# Check if the user entered a name
if [[ -n "$new_name" ]]; then
    swaymsg rename workspace to "$new_name"
fi
