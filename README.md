# gws

Persistent Ghostty workspaces on top of [zmx](https://github.com/neurosnap/zmx).

zmx keeps your shells alive. Ghostty draws the tabs and splits. gws connects the two:
a project file describes your panes, and `gws open` lays them out in Ghostty.
Close the window, come back later, and everything is still running.

One small binary, no daemon, no config required.

## Requirements

- macOS (`open`, `split` and `tab` drive Ghostty through AppleScript)
- [Ghostty](https://ghostty.org) 1.4+
- [zmx](https://github.com/neurosnap/zmx) 1.0.1+
- [fzf](https://github.com/junegunn/fzf)
- [Odin](https://odin-lang.org) to build

## Install

Homebrew (Apple Silicon):

```sh
brew install en9inerd/tap/gws
```

From source:

```sh
make install            # builds and copies gws to ~/.local/bin
make install PREFIX=/usr/local
```

The first `gws open` asks macOS for permission to control Ghostty. Allow it.

Optional keybinds for `~/.config/ghostty/config` (they type the command, so use them at a
shell prompt):

```ini
keybind = ctrl+b>f=text:gws\n
keybind = ctrl+b>v=text:gws split right\n
keybind = ctrl+b>s=text:gws split down\n
keybind = ctrl+b>c=text:gws tab\n
keybind = ctrl+b>x=text:gws kill\n
keybind = ctrl+b>shift+x=text:gws pick --kill\n
```

Tab titles: gws titles each pane with its session name (`myapp.editor`), and Ghostty's
tab bar shows the focused pane's title. Ghostty's shell integration replaces that title
with the directory or running command. To show the session name again at every prompt
(a running command still shows its own name), add this to `~/.zshrc`:

```zsh
# Inside zmx sessions: show the session name as the title at every prompt.
_zmx_title() { [[ -n "$ZMX_SESSION" ]] && printf '\e]0;%s\a' "$ZMX_SESSION"; }
precmd_functions+=(_zmx_title)  # keep this last in .zshrc
```

## Quick start

```sh
cd ~/Development/myapp
gws new myapp          # creates ~/.config/gws/projects/myapp.ini
gws edit myapp         # describe your panes
gws open myapp         # this terminal becomes the first pane, the rest open around it
```

Close the window when you're done; everything keeps running. `gws open myapp` brings it
back. `ctrl+\` detaches only the pane you're in.

## Commands

| Command | What it does |
|---------|--------------|
| `gws` | Pick a session, project, project pane or directory with fzf. A project opens its layout. |
| `gws pick --kill` | Pick a session to kill. |
| `gws new <name> [dir]` | Create a project. `dir` defaults to the current directory. |
| `gws edit [name]` | Edit a project file in `$EDITOR`. |
| `gws open [name] [--force]` | Open the project layout. From a plain Ghostty terminal the first tab is built right there; otherwise in new tabs. Panes already open in another window stay there and only the rest open; `--force` opens every pane again. |
| `gws attach <name>[.<pane>]` | Attach in this terminal. Starts the pane if needed. |
| `gws attach <dir>` | Attach to a session named after the directory (`.`, `./x`, `~/x`, `/x`). |
| `gws split [right\|left\|down\|up [name]]` | From a project pane: split it and add the new pane to the project, named `name` or numbered. |
| `gws tab [name]` | From a project pane: open a new tab and add its pane to the project. `open` restores it right after the tab it was opened from. |
| `gws list` | Show projects and sessions. |
| `gws kill [name[.pane]]` | Kill a project, pane or session. No argument: the current one. |
| `gws delete <name>[.<pane>] --yes` | Kill a project's panes and remove its file, or kill one pane and remove it from the file. |
| `gws version` | Print the version (also `-v`, `--version`). |

When `[name]` is left out, gws uses the project whose `dir` is the current directory, or
asks you to pick one.

## Project file

`~/.config/gws/projects/myapp.ini` (or `$XDG_CONFIG_HOME/gws/...` when that is set):

```ini
dir = ~/Development/myapp

[editor]
cmd = nvim .

[shell]
split = right

[server]
cmd = npm start
tab = run
```

The top-level `dir` is the project directory (absolute or `~/...`). Each `[section]` is a
pane and becomes a zmx session named `myapp.editor`, `myapp.shell`, ...

| Key | Default | Meaning |
|-----|---------|---------|
| `cmd` | plain shell | Runs when the pane starts. You get a shell back when it exits or on `ctrl+c`. |
| `tab` | `main` | Panes with the same tab share a Ghostty tab. |
| `split` | global `split`, else `right` | Where the pane goes relative to the one it splits: `right`, `left`, `down`, `up`. |
| `from` | previous pane in the tab | The pane it splits, an earlier pane in the same tab. `gws split` sets it. |
| `dir` | project `dir` | Working directory. Relative paths start from the project `dir`. |

Whole lines starting with `;` or `#` are comments.

## Global config (optional)

`~/.config/gws/config.ini`:

```ini
; directories offered by the picker, optionally with a depth
search = ~/Development
search = ~/Work:2
; default search depth and split direction
depth = 1
split = right
```

See [WORKFLOW.md](WORKFLOW.md) for a typical day with gws.

## Development

```sh
make          # build ./gws; version from `git describe` (override: make VERSION=1.2.3)
make check    # vet and style checks
make test     # unit tests, then CLI tests against fake zmx, osascript and fzf
make clean
```
