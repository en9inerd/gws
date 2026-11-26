# A day with gws

## Set up a project once

```sh
cd ~/Development/myapp
gws new myapp
gws edit myapp
```

Describe what you always have open:

```ini
dir = ~/Development/myapp

[editor]
cmd = nvim .

[shell]
split = down

[server]
cmd = npm run dev
tab = run
```

## Start the day

```sh
gws open myapp
```

The terminal you typed in becomes the editor, a shell opens below it, and a `run` tab
gets the dev server. Every pane is its own zmx session, so nothing dies when a window
closes. Detaching (`ctrl+\`) or killing a session closes its pane, the first one
included; the session itself survives a detach.

Run from inside a zmx session, `gws open` uses new tabs instead. From the project
directory, a plain `gws open` is enough.

## Need another pane or tab?

From any pane of the project:

```sh
gws split right
gws split down logs
gws tab db
```

Ghostty splits the pane or opens a tab, and the new pane is saved to the project file:
numbered (`myapp.2`) unless you give it a name (`myapp.logs`, `myapp.db`). There is no
save step: next time `gws open` splits the same pane again and puts a new tab back next
to the one it was opened from. Ghostty's own splits and tabs (`cmd+d`, `cmd+t`) are
plain shells: they are not saved and die with the window.

To remove a pane for good:

```sh
gws delete myapp.2 --yes
```

To rename it, `gws kill myapp.2` first, then `gws edit myapp`.

## Jump around

```sh
gws
```

The picker lists the current directory, other live sessions, projects, project panes
that aren't running, and the directories under your search paths. A project opens its
layout, and those panes close when you leave their sessions. Anything else, a single
project pane included, attaches in this terminal, and you're back in your shell when you
leave the session. Type a name that matches nothing and press enter to start a new
session with that name.

Inside a zmx session, picking another session switches to it instead of nesting.

To put a session in another tab or split, open one with `cmd+t` or `cmd+d` and pick
the session there. A session can be attached in several places at once.

For a quick throwaway session in the current directory:

```sh
gws attach .
```

## Take a break

Close the Ghostty window. The editor, shell and server keep running. Later:

```sh
gws open myapp           # the whole layout
gws attach myapp.server  # or one pane in this terminal
```

Closed just one pane by accident? `gws open myapp` reopens only what isn't open
anywhere: back next to its neighbours when its tab is still open, else in a new tab.
The rest of your window stays as it is. A pane you left with `ctrl+\` comes back the
same way.

`gws list` shows what's running.

## Restart something

```sh
gws kill myapp.server    # one pane
gws attach myapp.server  # starts it again with its cmd
```

`gws kill` with no argument kills the session you're in.

## End of the day

```sh
gws kill myapp           # stops every pane of the project
```

The project file stays, so tomorrow is one `gws open myapp` away.
To forget a project completely: `gws delete myapp --yes`.
