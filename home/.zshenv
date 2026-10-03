# Environment variables shared with bash. Sourced from .zshenv rather than
# .zshrc because zsh reads .zshenv for every shell, interactive or not -- the
# closest bash has is .bash_profile, which a non-login shell never reads.
if [ -f "$HOME/.environ" ]; then
  . "$HOME/.environ"
fi
