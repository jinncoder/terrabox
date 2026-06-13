# paradox.zsh
#
# Paradox-inspired prompt for stock zsh - sans 'oh-my-other-bloatware'...
#
# Install: add this line to ~/.zshrc
#   source /path/to/paradox.zsh
#
# Requirements:
#   - zsh 5.0+ with vcs_info (built-in)

# -- colour helpers ------------------------------------------------------------
# %{...%} tells zsh these bytes are zero-width (prevents tab-completion tearing)
_pdx_fg() {
  local r=$((16#${1:1:2})) g=$((16#${1:3:2})) b=$((16#${1:5:2}))
  printf '%%{\e[38;2;%d;%d;%dm%%}' "$r" "$g" "$b"
}
_PDX_RST=$'%{\e[0m%}'

# Named palette
_C_WHITE='#c8d3f5'    # user@host
_C_LBLUE='#91ddff'    # path
_C_GREEN='#95ffa4'    # git clean
_C_YELLOW='#ffe9aa'   # git dirty / root icon
_C_ORANGE='#ffb86c'   # git untracked
_C_RED='#ff8080'      # git conflicts / error
_C_PURPLE='#906cff'   # python
_C_DIM='#565f89'      # separators / brackets
_C_ARROW='#007ACC'    # second-line ❯

# Glyphs - $'...' expands \uXXXX at parse time (no runtime subshell needed)
_PL_SEP=$'\ue0b1'    # thin arrow  (path separator)
_PL_ARR=$'\ue0b0'    # solid arrow  (segment separator)
_ICON_BOLT=$'\uf0e7' # ⚡ root indicator
_ICON_PY=$'\ue235'   # python snake
_ICON_ERR=$'\ue20f'  # error glyph

# -- vcs_info setup ------------------------------------------------------------
autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' formats '%b'
zstyle ':vcs_info:git:*' actionformats '%b|%a'

# -- helpers -------------------------------------------------------------------
_pdx_arrow() {
  printf '%s%s%s' "$(_pdx_fg "$_C_DIM")" "$_PL_ARR" "$_PDX_RST"
}

_paradox_path() {
  local dim; dim="$(_pdx_fg "$_C_DIM")"
  local blu; blu="$(_pdx_fg "$_C_LBLUE")"
  local sep="${dim} ${_PL_SEP} ${blu}"
  local raw="${PWD/#$HOME/~}"
  printf '%s' "${raw//\//$sep}"
}

# Git branch coloured by working-tree state
_paradox_git() {
  [[ -z $vcs_info_msg_0_ ]] && return
  local branch="$vcs_info_msg_0_"
  local colour status_out
  status_out="$(git status --porcelain 2>/dev/null)" || return
  if [[ -z $status_out ]]; then
    colour="$_C_GREEN"
  elif printf '%s' "$status_out" | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
    colour="$_C_RED"
  elif printf '%s' "$status_out" | grep -qE '^[MADRCU]'; then
    colour="$_C_YELLOW"
  else
    colour="$_C_ORANGE"
  fi
  printf '%s%s%s' "$(_pdx_fg "$colour")" "$branch" "$_PDX_RST"
}

# Python version - only inside a Python project tree or active venv
_paradox_python() {
  local dir="$PWD" found=0
  while [[ "$dir" != "/" && "$dir" != "$HOME" ]]; do
    for marker in pyproject.toml setup.py setup.cfg requirements.txt Pipfile .python-version; do
      [[ -e "$dir/$marker" ]] && { found=1; break 2; }
    done
    [[ -d "$dir/.git" ]] && break
    dir="${dir:h}"
  done
  [[ -n $VIRTUAL_ENV ]] && found=1
  [[ $found -eq 0 ]] && return
  local ver='' venv=''
  [[ -n $VIRTUAL_ENV ]] && venv="$(basename "$VIRTUAL_ENV") "
  if command -v python3 &>/dev/null; then
    ver="$(python3 --version 2>&1 | awk '{print $2}')"
  elif command -v python &>/dev/null; then
    ver="$(python --version 2>&1 | awk '{print $2}')"
  fi
  [[ -n $ver || -n $venv ]] && printf '%s %s%s' "$_ICON_PY" "$venv" "$ver"
}

# -- build prompt --------------------------------------------------------------
_paradox_build_prompt() {
  local exit_code=$1 out=''

  # Root indicator (only when UID=0)
  if [[ $EUID -eq 0 ]]; then
    out+="$(_pdx_fg "$_C_YELLOW") ${_ICON_BOLT} ${_PDX_RST}$(_pdx_arrow)"
  fi

  # user@host
  out+=" $(_pdx_fg "$_C_WHITE")${USER}@${HOST%%.*}${_PDX_RST} $(_pdx_arrow)"

  # path
  out+=" $(_pdx_fg "$_C_LBLUE")$(_paradox_path)${_PDX_RST} "

  # git [branch]
  local _git; _git="$(_paradox_git)"
  if [[ -n $_git ]]; then
    out+=" $(_pdx_fg "$_C_DIM")[${_PDX_RST}${_git}$(_pdx_fg "$_C_DIM")]${_PDX_RST} "
  fi

  # python (project-aware)
  local _py; _py="$(_paradox_python)"
  if [[ -n $_py ]]; then
    out+="$(_pdx_arrow) $(_pdx_fg "$_C_PURPLE")${_py}${_PDX_RST} "
  fi

  # error indicator
  if [[ $exit_code -ne 0 ]]; then
    out+="$(_pdx_arrow) $(_pdx_fg "$_C_RED")${_ICON_ERR}${_PDX_RST} "
  fi

  # line 2
  out+=$'\n'
  out+="$(_pdx_fg "$_C_ARROW")❯${_PDX_RST} "

  printf '%s' "$out"
}

# -- hooks - use add-zsh-hook so we don't clobber other precmd handlers --------
autoload -Uz add-zsh-hook

_paradox_last_status=0

_paradox_precmd() {
  _paradox_last_status=$?
  vcs_info
}

add-zsh-hook precmd _paradox_precmd

# -- keybindings ---------------------------------------------------------------
# Use emacs-style line editing
bindkey -e

# Home / End
bindkey '^[[H'    beginning-of-line   # Home (VT/xterm)
bindkey '^[[1~'   beginning-of-line   # Home (rxvt/screen)
bindkey '^[OH'    beginning-of-line   # Home (application mode)
bindkey '^[[F'    end-of-line         # End  (VT/xterm)
bindkey '^[[4~'   end-of-line         # End  (rxvt/screen)
bindkey '^[OF'    end-of-line         # End  (application mode)

# Delete / Backspace
bindkey '^[[3~'   delete-char          # Delete
bindkey '^?'      backward-delete-char # Backspace
bindkey '^H'      backward-delete-char # Backspace (some terminals)

# Shift+Delete - delete word forward (most common expectation)
bindkey '^[[3;2~' kill-word           # Shift+Delete (VT/xterm)
bindkey '^[[3$'   kill-word           # Shift+Delete (rxvt)

# Ctrl+Delete - delete word forward
bindkey '^[[3;5~' kill-word           # Ctrl+Delete (VT/xterm)
bindkey '^[[3^'   kill-word           # Ctrl+Delete (rxvt)

# Ctrl+Backspace - delete word backward
bindkey '^H'      backward-kill-word  # Ctrl+Backspace (most terminals)
bindkey '^_'      backward-kill-word  # Ctrl+Backspace (some terminals)

# Ctrl+Left / Ctrl+Right - skip words
bindkey '^[[1;5D' backward-word       # Ctrl+Left  (VT/xterm)
bindkey '^[[1;5C' forward-word        # Ctrl+Right (VT/xterm)
bindkey '^[Od'    backward-word       # Ctrl+Left  (rxvt)
bindkey '^[Oc'    forward-word        # Ctrl+Right (rxvt)

# Alt+Left / Alt+Right - skip words (common alternative)
bindkey '^[[1;3D' backward-word       # Alt+Left  (VT/xterm)
bindkey '^[[1;3C' forward-word        # Alt+Right (VT/xterm)
bindkey '^[^[[D'  backward-word       # Alt+Left  (some terminals)
bindkey '^[^[[C'  forward-word        # Alt+Right (some terminals)

# Alt+Backspace - delete word backward
bindkey '^[^?'    backward-kill-word  # Alt+Backspace
bindkey '^[^H'    backward-kill-word  # Alt+Backspace (some terminals)

# Ctrl+Left/Right in vi-style word units (uses bash-style word boundaries)
bindkey '^[b'     backward-word       # Alt+B (readline compat)
bindkey '^[f'     forward-word        # Alt+F (readline compat)

# Page Up / Page Down - history search
bindkey '^[[5~'   history-search-backward  # PgUp
bindkey '^[[6~'   history-search-forward   # PgDn

# Ctrl+U - kill to beginning of line (readline default, sometimes missing)
bindkey '^U'      backward-kill-line

# Ctrl+K - kill to end of line
bindkey '^K'      kill-line

# Ctrl+W - kill word backward (readline default)
bindkey '^W'      backward-kill-word

# Ctrl+Y - yank (paste killed text)
bindkey '^Y'      yank

# Ctrl+A / Ctrl+E - beginning / end of line (readline defaults, ensure present)
bindkey '^A'      beginning-of-line
bindkey '^E'      end-of-line

# -- prompt --------------------------------------------------------------------
setopt PROMPT_SUBST
PROMPT='$(_paradox_build_prompt $_paradox_last_status)'
RPROMPT=''
