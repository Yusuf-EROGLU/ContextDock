# ContextDock Ghostty/zsh integration (optional).
#
# Source this file from your ~/.zshrc:
#     source /path/to/ContextDock/Integrations/Ghostty/contextdock.zsh
#
# It adds three commands that set a display label for this terminal via the window title
# (OSC 2), using the versioned format  CDOCK:v1|label=…|project=…|branch=…
#
#     contextdock_label "Backend"        # set the card label
#     contextdock_project "backend"      # optional project name shown on the card
#     contextdock_clear                  # back to Ghostty's normal title
#
# Nothing is emitted until you set a label, so normal titles are untouched. The hook runs no
# git commands and never publishes your user name or full paths. Fields are sanitized and
# percent-encoded; ContextDock treats them as display-only text.

[[ -o interactive ]] || return 0

typeset -g CONTEXTDOCK_LABEL="${CONTEXTDOCK_LABEL:-}"
typeset -g CONTEXTDOCK_PROJECT="${CONTEXTDOCK_PROJECT:-}"
typeset -g CONTEXTDOCK_BRANCH="${CONTEXTDOCK_BRANCH:-}"

_contextdock_sanitize() {
  # Drop control characters (incl. ESC), the field separators, and cap the length.
  local value="$1"
  value="${value//[[:cntrl:]]/}"
  value="${value//|/}"
  value="${value//=/}"
  print -r -- "${value[1,64]}"
}

_contextdock_pct() {
  # Percent-encode every byte outside [A-Za-z0-9._~-].
  local LC_ALL=C
  local input="$1" out="" ch
  local i
  for (( i = 1; i <= ${#input}; i++ )); do
    ch="${input[i]}"
    case "$ch" in
      [A-Za-z0-9._~-]) out+="$ch" ;;
      *) out+="$(printf '%%%02X' "'$ch")" ;;
    esac
  done
  print -r -- "$out"
}

_contextdock_emit() {
  [[ -n "$CONTEXTDOCK_LABEL" || -n "$CONTEXTDOCK_PROJECT" || -n "$CONTEXTDOCK_BRANCH" ]] || return 0
  local title="CDOCK:v1"
  [[ -n "$CONTEXTDOCK_LABEL" ]]   && title+="|label=$(_contextdock_pct "$CONTEXTDOCK_LABEL")"
  [[ -n "$CONTEXTDOCK_PROJECT" ]] && title+="|project=$(_contextdock_pct "$CONTEXTDOCK_PROJECT")"
  [[ -n "$CONTEXTDOCK_BRANCH" ]]  && title+="|branch=$(_contextdock_pct "$CONTEXTDOCK_BRANCH")"
  printf '\e]2;%s\a' "$title"
}

contextdock_label() {
  CONTEXTDOCK_LABEL="$(_contextdock_sanitize "$*")"
  _contextdock_emit
}

contextdock_project() {
  CONTEXTDOCK_PROJECT="$(_contextdock_sanitize "$*")"
  _contextdock_emit
}

contextdock_branch() {
  CONTEXTDOCK_BRANCH="$(_contextdock_sanitize "$*")"
  _contextdock_emit
}

contextdock_clear() {
  CONTEXTDOCK_LABEL="" CONTEXTDOCK_PROJECT="" CONTEXTDOCK_BRANCH=""
  printf '\e]2;%s\a' "${PWD:t}"
}

# Re-emit the title before every prompt so programs that change the title do not win
# permanently. Uses add-zsh-hook, so existing precmd functions are preserved.
autoload -Uz add-zsh-hook
add-zsh-hook precmd _contextdock_emit
