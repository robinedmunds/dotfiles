#!/bin/bash
# list explicitly installed packages from pacman and flatkpak and store in respective files

printf '\n\nPACMAN PACKAGES\n\n'
pacman -Qeq | tee pacman.txt

printf '\n\n\nFLATPAK PACKAGES\n\n'
flatpak list --app --columns=app | tail -n +1 | tee flatpak.txt
