#!/usr/bin/env bash

cd `mktemp -d`

wget "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.12.7/obsidian_1.12.7_amd64.deb" && apt-get install -y -qq ./obsidian*.deb

