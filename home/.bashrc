#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Environment variables shared with zsh
if [ -f "$HOME/.environ" ]; then
  . "$HOME/.environ"
fi

# Aliases shared with zsh
if [ -f "$HOME/.aliases" ]; then
  . "$HOME/.aliases"
fi
PS1='[\u@\h \W]\$ '
