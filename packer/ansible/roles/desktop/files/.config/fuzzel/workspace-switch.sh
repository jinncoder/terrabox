#!/bin/bash
# Get the list of active workspace names, separated by newlines, and pass to fuzzel
target_workspace=$(swaymsg -t get_workspaces | jq -r '.[].name' | fuzzel --dmenu -p "Switch to Workspace: ")

# If a workspace was selected, send the command to Sway
if [ -n "$target_workspace" ]; then
    swaymsg workspace "$target_workspace"
fi

