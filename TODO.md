# TODO

- Wait for Ghostty to fix [#13167](https://github.com/ghostty-org/ghostty/discussions/13167)
  (an AppleScript `command` always keeps the pane open after it exits, ignoring
  `wait after command = false`). gws could then start panes with `command` and
  `wait after command = false` instead of typing ` exec gws attach ...` into a shell:
  simple, no shell history entries, no `HIST_IGNORE_SPACE` setting. About 10 lines in
  `write_surface_config`.
- Linux support for `open`, `split` and `tab`, once Ghostty has a scripting API there.
  They drive Ghostty through AppleScript, which exists only on macOS; Linux needs an
  equivalent way to create tabs and splits with a working directory and a command or
  initial input, and to find the terminal gws runs in. `attach`, `pick`, `list` and `kill`
  only need zmx and already work there.
