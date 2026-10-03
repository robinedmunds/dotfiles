#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

export PATH="${PATH}:/home/robin/.local/bin/"
export KWIN_IM_SHOW_ALWAYS=1  # always show virtual keyboard
