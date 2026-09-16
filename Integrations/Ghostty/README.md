# ContextDock Ghostty integration (optional)

Ghostty windows appear in ContextDock automatically (one card per window, labelled with the
window title). This optional zsh snippet lets you name a terminal from the shell:

```zsh
source /path/to/ContextDock/Integrations/Ghostty/contextdock.zsh   # add to ~/.zshrc yourself
contextdock_label "Backend"
contextdock_project "backend"     # optional
contextdock_clear                 # remove the label
```

The commands write the window title with OSC 2 in the versioned format
`CDOCK:v1|label=Backend|project=backend`. ContextDock parses it as **display-only** text:
it never treats a value as a path, never runs anything from it, and never persists it. Malformed
or unknown-version titles fall back to the plain title.

ContextDock never edits your `.zshrc` or Ghostty configuration; you add the `source` line.
Uninstall by removing that line. The hook is registered with `add-zsh-hook precmd`, so your
existing `precmd` functions keep working. It runs no `git` commands on each prompt; use
*Attach Project Folder…* on the card for branch information.

## Compatibility notes

- **`title` in Ghostty config**: a fixed `title = …` setting overrides OSC 2, so labels will not
  show. Remove that setting to use this integration.
- **Shell integration title feature**: Ghostty's shell integration may also write titles. If
  labels get overwritten, set `shell-integration-features = no-title` in the Ghostty config.
- **Tabs and splits**: ContextDock shows one card per *window*. The title reflects whichever
  surface Ghostty reports as the window title (usually the focused split/tab); splits and tabs
  are not separate cards.
- **SSH / tmux / TUI apps**: a remote shell, tmux or a full-screen program may set its own title;
  the label is re-emitted at the next local prompt. Inside tmux, OSC passthrough must be enabled
  for the title to reach Ghostty.
- **Other shells**: the snippet is zsh-only. In any case, the card's *Rename…* action works
  regardless of what the title says.
