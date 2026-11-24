#!/bin/sh
# End-to-end tests of the gws binary. Fake zmx, osascript and fzf on PATH record how
# they were called, so every command runs without zmx sessions, Ghostty or a terminal.
#
# Usage: sh tests/cli.sh [path/to/gws]

set -u

GWS=$(cd "$(dirname "${1:-./gws}")" && pwd)/$(basename "${1:-./gws}")
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export SHELL=/bin/sh
export PATH="$WORK/bin:/usr/bin:/bin"
export FAKE_LOG="$WORK/calls"            # one line per zmx call
export FAKE_SCRIPTS="$WORK/scripts"      # every AppleScript passed to osascript
export FAKE_ZMX_LIST="$WORK/zmx-list"    # what `zmx list` prints
export FAKE_FZF_INPUT="$WORK/fzf-input"  # what gws sent to fzf
unset ZMX_SESSION TERM_PROGRAM EDITOR FAKE_OSASCRIPT_FAIL FAKE_FZF_OUTPUT FAKE_FZF_EXIT

PROJECTS="$XDG_CONFIG_HOME/gws/projects"
APP="$HOME/Development/app"
mkdir -p "$WORK/bin" "$APP/api" "$HOME/Development/other.dir" "$HOME/Development/.hidden"

cat > "$WORK/bin/zmx" << 'EOF'
#!/bin/sh
echo "zmx $*" >> "$FAKE_LOG"
if [ "$1" = list ]; then cat "$FAKE_ZMX_LIST" 2> /dev/null; fi
# Signals ignored by gws carry over into zmx and its shells.
if [ "$1" = attach ]; then
	perl -e 'print "sigpipe=", ($SIG{PIPE} || "default"), "\n"' >> "$FAKE_LOG"
	echo "attach env: ZMX_SESSION=${ZMX_SESSION:-} cwd=$(pwd -P)" >> "$FAKE_LOG"
fi
exit 0
EOF

cat > "$WORK/bin/osascript" << 'EOF'
#!/bin/sh
printf '%s\n' "$2" >> "$FAKE_SCRIPTS"
if [ -n "${FAKE_OSASCRIPT_FAIL:-}" ]; then echo "boom" >&2; exit 1; fi
exit 0
EOF

# FAKE_FZF_OUTPUT is printed with escapes (\n) expanded; FAKE_FZF_EXIT is the exit code.
cat > "$WORK/bin/fzf" << 'EOF'
#!/bin/sh
cat > "$FAKE_FZF_INPUT"
if [ -n "${FAKE_FZF_OUTPUT:-}" ]; then printf '%b\n' "$FAKE_FZF_OUTPUT"; fi
exit "${FAKE_FZF_EXIT:-0}"
EOF
chmod +x "$WORK/bin/zmx" "$WORK/bin/osascript" "$WORK/bin/fzf"

passed=0
failed=0

# Runs gws with fresh logs; sets $out (stdout and stderr) and $code. Variables given as
# `VAR=value gws ...` are passed on explicitly and cleared afterwards, because shells
# differ in whether such assignments outlive a function call.
gws() {
	: > "$FAKE_LOG"
	: > "$FAKE_SCRIPTS"
	: > "$FAKE_FZF_INPUT"
	out=$(env \
		ZMX_SESSION="${ZMX_SESSION:-}" \
		EDITOR="${EDITOR:-}" \
		FAKE_OSASCRIPT_FAIL="${FAKE_OSASCRIPT_FAIL:-}" \
		FAKE_FZF_OUTPUT="${FAKE_FZF_OUTPUT:-}" \
		FAKE_FZF_EXIT="${FAKE_FZF_EXIT:-0}" \
		"$GWS" "$@" 2>&1)
	code=$?
	unset ZMX_SESSION EDITOR FAKE_OSASCRIPT_FAIL FAKE_FZF_OUTPUT FAKE_FZF_EXIT
}

# gws_in <dir> <args...>: gws run from dir.
gws_in() {
	gws_in_back=$PWD
	cd "$1" || exit 1
	shift
	gws "$@"
	cd "$gws_in_back" || exit 1
}

ok() {
	passed=$((passed + 1))
}

bad() {
	failed=$((failed + 1))
	printf 'FAIL: %s\n' "$1"
	printf '  output: %s\n' "$out" | head -20
}

# expect_code <code> <description>
expect_code() {
	if [ "$code" = "$1" ]; then ok; else bad "$2: exit $code, want $1"; fi
}

# expect_out <text> <description>
expect_out() {
	case "$out" in *"$1"*) ok ;; *) bad "$2: output lacks '$1'" ;; esac
}

expect_no_out() {
	case "$out" in *"$1"*) bad "$2: output has '$1'" ;; *) ok ;; esac
}

# expect_file <file> <text> <description>
expect_file() {
	if grep -qF -- "$2" "$1" 2> /dev/null; then ok; else bad "$3: $(basename "$1") lacks '$2'"; fi
}

expect_no_file_text() {
	if grep -qF -- "$2" "$1" 2> /dev/null; then bad "$3: $(basename "$1") has '$2'"; else ok; fi
}

sessions() {
	printf '%s\n' "$@" > "$FAKE_ZMX_LIST"
}

session_line() {
	printf '  name=%s\tpid=1\tclients=%s\tcreated=0\tcwd=file://host%s' "$1" "$2" "$3"
}

macos=false
if [ "$(uname)" = Darwin ]; then macos=true; fi

# --- usage --------------------------------------------------------------------------

gws help
expect_code 0 "help"
expect_out "Usage:" "help"
gws --help
expect_code 0 "--help"

for flag in version -v --version; do
	gws "$flag"
	expect_code 0 "$flag"
	case "$out" in "gws "?*) ok ;; *) bad "$flag prints 'gws <version>'" ;; esac
done

gws frob
expect_code 2 "unknown command"
expect_out 'unknown command "frob"' "unknown command"

gws new --bogus
expect_code 1 "unknown option"
expect_out "unknown option --bogus" "unknown option"

gws new
expect_code 2 "new without name"
gws new a b c
expect_code 2 "new with too many arguments"
gws attach
expect_code 2 "attach without target"
gws kill a b
expect_code 2 "kill with two targets"
gws delete
expect_code 2 "delete without target"
gws list extra
expect_code 2 "list with an argument"
gws pick extra
expect_code 2 "pick with an argument"

# --- new, edit ----------------------------------------------------------------------

gws list
expect_code 0 "list with nothing"
expect_out "no projects or sessions" "list with nothing"

gws new app "$APP"
expect_code 0 "new"
expect_out "created ~/.config/gws/projects/app.ini" "new"
if [ "$(cat "$PROJECTS/app.ini")" = "$(printf 'dir = ~/Development/app\n\n[shell]')" ]; then ok; else bad "new writes the project file"; fi

gws new app "$APP"
expect_code 1 "new existing"
expect_out 'project "app" already exists' "new existing"
gws new bad.name
expect_code 1 "new invalid name"
expect_out 'invalid project name "bad.name"' "new invalid name"
gws new nodir "$WORK/missing"
expect_code 1 "new missing dir"
expect_out "not a directory: $WORK/missing" "new missing dir"

gws_in "$APP/api" new api
expect_file "$PROJECTS/api.ini" "dir = ~/Development/app/api" "new defaults to the current dir"
rm "$PROJECTS/api.ini"

cat > "$PROJECTS/app.ini" << 'EOF'
dir = ~/Development/app

[editor]
cmd = nvim .

[shell]
split = down

[server]
cmd = npm start
tab = run
dir = api
EOF

EDITOR=cat gws edit app
expect_code 0 "edit"
expect_out "[server]" "edit runs \$EDITOR on the file"
gws edit missing
expect_code 1 "edit missing"
expect_out 'project "missing" not found' "edit missing"

# With one project, an omitted name needs no picker.
EDITOR=cat gws_in "$WORK" edit
expect_out "[editor]" "edit picks the only project"

# --- list ---------------------------------------------------------------------------

sessions "$(session_line app.editor 1 "$APP")" "$(session_line misc 0 /tmp)" \
	"  name=dead	err=ConnectionRefused	status=unreachable"
gws list
expect_code 0 "list"
expect_out "PROJECT              PANES   DIR" "list header"
expect_out "app                  1/3     ~/Development/app" "list counts live panes"
expect_out "SESSION              PID     CLIENTS DIR" "list sessions header"
expect_out "misc                 1       0       /tmp" "list other sessions"
expect_no_out "app.editor" "list hides project sessions"
expect_no_out "dead" "list hides dead sessions"

printf 'dir = relative\n' > "$PROJECTS/broken.ini"
gws list
expect_code 0 "list with a broken project"
expect_out "broken               error" "list shows project errors"
rm "$PROJECTS/broken.ini"

# --- attach -------------------------------------------------------------------------

sessions "$(session_line misc 0 /tmp)"
gws attach app.server
expect_code 0 "attach pane"
expect_out "$(printf '\033]0;app.server\007')" "attach sets the terminal title"
expect_file "$FAKE_LOG" "zmx attach app.server /bin/sh -c trap \"exec '/bin/sh'\" INT" "attach runs the pane cmd"
expect_file "$FAKE_LOG" "npm start" "attach runs the pane cmd"

gws attach app
expect_file "$FAKE_LOG" "zmx attach app.editor /bin/sh -c" "attach project uses its first pane"

gws attach app.shell
expect_file "$FAKE_LOG" "zmx attach app.shell" "attach bare pane"
expect_no_file_text "$FAKE_LOG" "app.shell /bin/sh" "attach bare pane has no cmd"

gws attach misc
expect_code 0 "attach live session"
expect_file "$FAKE_LOG" "zmx attach misc" "attach live session"

gws attach nosuch
expect_code 1 "attach unknown"
expect_out 'no project pane or session named "nosuch"' "attach unknown"
gws attach app.nosuch
expect_code 1 "attach unknown pane"

gws_in "$HOME/Development/other.dir" attach .
expect_file "$FAKE_LOG" "zmx attach other_dir" "attach . names the session after the dir"
gws attach "$APP/api"
expect_file "$FAKE_LOG" "zmx attach api" "attach absolute dir"
gws attach ~/Development/app
expect_file "$FAKE_LOG" "zmx attach app" "attach ~ dir"
gws attach ./missing
expect_code 1 "attach missing dir"
expect_out "not a directory: ./missing" "attach missing dir"

# Inside a session, missing panes are created detached first, then attached.
ZMX_SESSION=misc gws attach app.server
expect_file "$FAKE_LOG" "zmx attach app.server /bin/sh -c trap" "attach inside zmx creates the pane"
expect_file "$FAKE_LOG" "attach env: ZMX_SESSION= cwd=$APP/api" "attach inside zmx creates the pane in its dir"
expect_file "$FAKE_LOG" "attach env: ZMX_SESSION=misc" "attach inside zmx switches"
ZMX_SESSION=misc gws attach app.shell
expect_file "$FAKE_LOG" "attach env: ZMX_SESSION= cwd=$APP" "attach inside zmx creates a bare pane"
expect_no_file_text "$FAKE_LOG" "zmx attach app.shell /bin/sh" "attach inside zmx starts a bare pane with the default shell"
sessions "$(session_line misc 0 /tmp)" "$(session_line app.shell 0 "$APP")"
ZMX_SESSION=misc gws attach app.shell
expect_no_file_text "$FAKE_LOG" "attach env: ZMX_SESSION= " "attach inside zmx reuses a live pane"

# --- open ---------------------------------------------------------------------------

if $macos; then
	sessions "$(session_line misc 1 /tmp)"
	gws open app
	expect_code 0 "open"
	expect_out "opened app" "open"
	expect_file "$FAKE_SCRIPTS" "set pane1 to split pane0 direction down with configuration cfg" "open splits"
	expect_file "$FAKE_SCRIPTS" "new tab in front window" "open makes tabs"
	expect_file "$FAKE_SCRIPTS" "attach 'app.server'" "open attaches panes"
	expect_file "$FAKE_SCRIPTS" "set initial working directory of cfg to \"$APP/api\"" "open uses pane dirs"

	gws_in "$APP" open
	expect_out "opened app" "open without name uses the current dir"

	# Partly open: only the panes nobody is attached to open.
	sessions "$(session_line app.shell 1 "$APP")" "$(session_line app.server 0 "$APP/api")"
	gws open app
	expect_code 0 "open when partly open"
	expect_out "opened app (2 of 3 panes; the rest are open elsewhere)" "open when partly open"
	expect_no_file_text "$FAKE_SCRIPTS" "attach 'app.shell'" "open skips attached panes"
	expect_file "$FAKE_SCRIPTS" "attach 'app.editor'" "open reopens a detached pane"
	expect_file "$FAKE_SCRIPTS" "attach 'app.server'" "open reopens a live detached pane"

	sessions "$(session_line app.editor 1 "$APP")" "$(session_line app.shell 1 "$APP")" "$(session_line app.server 2 "$APP/api")"
	gws open app
	expect_code 1 "open when fully open"
	expect_out "app is already open; use --force" "open when fully open"
	gws open app --force
	expect_code 0 "open --force"
	expect_out "opened app" "open --force"
	expect_file "$FAKE_SCRIPTS" "attach 'app.shell'" "open --force opens every pane"

	sessions ""
	FAKE_OSASCRIPT_FAIL=1 gws open app
	expect_code 1 "open when AppleScript fails"
	expect_out "Ghostty AppleScript failed: boom" "open when AppleScript fails"

	gws open missing
	expect_code 1 "open missing project"
	printf 'dir = ~/Development/app\n' > "$PROJECTS/empty.ini"
	gws open empty
	expect_code 1 "open without panes"
	expect_out 'project "empty" has no panes' "open without panes"
	printf 'dir = ~/Development/app\n[x]\ndir = gone\n' > "$PROJECTS/empty.ini"
	gws open empty
	expect_code 1 "open with a missing pane dir"
	expect_out "empty.x: not a directory: $APP/gone" "open with a missing pane dir"
	rm "$PROJECTS/empty.ini"
else
	gws open app
	expect_code 1 "open off macOS"
	expect_out "open is not supported on linux" "open off macOS"
fi

# --- split, tab ---------------------------------------------------------------------

if $macos; then
	sessions "$(session_line app.editor 1 "$APP")"
	gws split
	expect_code 1 "split outside zmx"
	expect_out "not inside a zmx session" "split outside zmx"
	ZMX_SESSION=misc gws split
	expect_code 1 "split outside a project"
	expect_out 'session "misc" is not part of a gws project' "split outside a project"
	ZMX_SESSION=app.editor gws split sideways
	expect_code 1 "split bad direction"
	ZMX_SESSION=app.editor gws split right logs extra
	expect_code 2 "split with too many arguments"
	ZMX_SESSION=app.editor gws split right bad.name
	expect_code 1 "split with an invalid name"
	expect_out 'invalid pane name "bad.name"' "split with an invalid name"
	ZMX_SESSION=app.editor gws split right shell
	expect_code 1 "split with a taken name"
	expect_out '"shell" is already a pane, tab or session of app' "split with a taken name"

	ZMX_SESSION=app.editor gws split right
	expect_code 0 "split"
	expect_out "added app.2 (right)" "split"
	expect_file "$FAKE_SCRIPTS" "split p direction right with configuration cfg" "split script"
	expect_file "$FAKE_SCRIPTS" "attach 'app.2'" "split attaches the new pane"
	if [ "$(tail -4 "$PROJECTS/app.ini")" = "$(printf '[2]\ntab = main\nsplit = right\nfrom = editor')" ]; then ok; else bad "split appends the pane"; fi

	printf 'split = up\n' > "$XDG_CONFIG_HOME/gws/config.ini"
	ZMX_SESSION=app.server gws split
	expect_out "added app.3 (up)" "split uses the configured default"
	expect_file "$PROJECTS/app.ini" "dir = ~/Development/app/api" "split keeps the current pane dir"
	rm "$XDG_CONFIG_HOME/gws/config.ini"

	before=$(cat "$PROJECTS/app.ini")
	ZMX_SESSION=app.editor FAKE_OSASCRIPT_FAIL=1 gws split
	expect_code 1 "split when AppleScript fails"
	if [ "$(cat "$PROJECTS/app.ini")" = "$before" ]; then ok; else bad "split restores the file on failure"; fi

	ZMX_SESSION=app.editor gws tab
	expect_code 0 "tab"
	expect_out "added app.4 (tab)" "tab"
	expect_file "$FAKE_SCRIPTS" "new tab in front window with configuration cfg" "tab script"
	# The new tab sits right after main, so its section goes before [server] (tab run).
	order=$(grep -n -e '^\[4\]' -e '^\[server\]' "$PROJECTS/app.ini" | cut -d: -f2 | tr '\n' ' ')
	if [ "$order" = "[4] [server] " ]; then ok; else bad "tab section goes before the next tab: $order"; fi
	expect_file "$PROJECTS/app.ini" "tab = 4" "tab names the tab after the pane"
	gws tab x y
	expect_code 2 "tab with two arguments"

	ZMX_SESSION=app.editor gws split down logs
	expect_out "added app.logs (down)" "split with a name"
	expect_file "$FAKE_SCRIPTS" "attach 'app.logs'" "split with a name attaches it"
	expect_file "$PROJECTS/app.ini" "[logs]" "split with a name saves it"
	ZMX_SESSION=app.editor gws tab db
	expect_out "added app.db (tab)" "tab with a name"
	expect_file "$PROJECTS/app.ini" "tab = db" "tab with a name names the tab too"
	gws delete app.logs --yes > /dev/null
	gws delete app.db --yes > /dev/null

	gws list
	expect_out "app                  1/6" "list sees the added panes"

	# Restore: open rebuilds what split and tab made, each pane in its tab and position.
	sessions ""
	gws open app
	expect_code 0 "open after split and tab"
	expect_file "$FAKE_SCRIPTS" "set pane1 to split pane0 direction down" "restore keeps the shell split"
	expect_file "$FAKE_SCRIPTS" "set pane4 to split pane0 direction right" "restore splits app.2 from the editor"
	expect_file "$FAKE_SCRIPTS" "set pane5 to split pane3 direction up" "restore splits app.3 from the server"
	line_of() { grep -n "attach '$1'" "$FAKE_SCRIPTS" | head -1 | cut -d: -f1; }
	if [ "$(line_of app.2)" -lt "$(line_of app.4)" ] && [ "$(line_of app.4)" -lt "$(line_of app.server)" ]; then
		ok
	else
		bad "restore opens tabs in order main, 4, run"
	fi
else
	ZMX_SESSION=app.editor gws split right
	expect_code 1 "split off macOS"
	expect_out "split is not supported on linux" "split off macOS"
	ZMX_SESSION=app.editor gws tab
	expect_out "tab is not supported on linux" "tab off macOS"
	printf '\n[2]\ntab = main\n\n[3]\ntab = run\n' >> "$PROJECTS/app.ini"
fi

# --- kill ---------------------------------------------------------------------------

sessions "$(session_line app.editor 1 "$APP")" "$(session_line app.shell 0 "$APP")" "$(session_line misc 0 /tmp)"
gws kill
expect_code 2 "kill outside zmx"
ZMX_SESSION=misc gws kill
expect_file "$FAKE_LOG" "zmx kill misc" "kill current session"
gws kill app
expect_out "killing app.editor app.shell" "kill project"
expect_file "$FAKE_LOG" "zmx kill app.editor app.shell" "kill project"
gws kill app.shell
expect_file "$FAKE_LOG" "zmx kill app.shell" "kill pane"
gws kill misc
expect_file "$FAKE_LOG" "zmx kill misc" "kill session"
gws kill nosuch
expect_code 1 "kill unknown"
expect_out 'no live session or project panes named "nosuch"' "kill unknown"

# --- pick ---------------------------------------------------------------------------

sessions "$(session_line misc 0 /tmp)" "$(session_line app.editor 1 "$APP")"
FAKE_FZF_EXIT=130 gws_in "$APP"
expect_file "$FAKE_FZF_INPUT" "[here] $APP" "picker offers the current dir"
expect_file "$FAKE_FZF_INPUT" "[zmx] misc" "picker offers sessions"
expect_file "$FAKE_FZF_INPUT" "[project] app" "picker offers projects"
expect_file "$FAKE_FZF_INPUT" "[pane] app.shell" "picker offers stopped panes"
expect_no_file_text "$FAKE_FZF_INPUT" "[pane] app.editor" "picker skips live panes"
expect_file "$FAKE_FZF_INPUT" "$HOME/Development/other.dir" "picker offers search dirs"
expect_no_file_text "$FAKE_FZF_INPUT" ".hidden" "picker skips hidden dirs"
if [ "$(cat "$FAKE_LOG")" = "zmx list" ]; then ok; else bad "cancelled picker does nothing"; fi

ZMX_SESSION=misc FAKE_FZF_EXIT=130 gws pick
expect_no_file_text "$FAKE_FZF_INPUT" "[zmx] misc" "picker hides the current session"
expect_file "$FAKE_FZF_INPUT" "[zmx] app.editor" "picker keeps the other sessions"

FAKE_FZF_OUTPUT='\n[zmx] misc                     pid:1       clients:0  /tmp' gws pick
expect_file "$FAKE_LOG" "zmx attach misc" "pick a session"
expect_file "$FAKE_LOG" "sigpipe=default" "pick leaves SIGPIPE at its default for zmx"
FAKE_FZF_OUTPUT='\n[pane] app.shell' gws pick
expect_file "$FAKE_LOG" "zmx attach app.shell" "pick a pane"
FAKE_FZF_OUTPUT="\n$HOME/Development/other.dir" gws pick
expect_file "$FAKE_LOG" "zmx attach other_dir" "pick a dir"
FAKE_FZF_OUTPUT="\n[here] $APP/api" gws pick
expect_file "$FAKE_LOG" "zmx attach api" "pick the current dir"
FAKE_FZF_OUTPUT='new thing!' FAKE_FZF_EXIT=1 gws pick
expect_file "$FAKE_LOG" "zmx attach new_thing_" "pick a new session name"
FAKE_FZF_OUTPUT='' FAKE_FZF_EXIT=1 gws pick
expect_code 0 "pick nothing"
if $macos; then
	sessions ""
	FAKE_FZF_OUTPUT='\n[project] app' gws pick
	expect_out "opened app" "pick a project opens it"
fi

sessions "$(session_line misc 0 /tmp)" "$(session_line app.editor 1 "$APP")"
FAKE_FZF_OUTPUT='misc' gws pick --kill
expect_file "$FAKE_FZF_INPUT" "app.editor" "pick --kill lists sessions"
expect_file "$FAKE_LOG" "zmx kill misc" "pick --kill kills the selection"
FAKE_FZF_EXIT=130 gws pick --kill
expect_no_file_text "$FAKE_LOG" "zmx kill" "pick --kill cancelled"
sessions ""
gws pick --kill
expect_out "no live sessions" "pick --kill without sessions"

# Two projects: the current dir decides, else the picker.
gws new second "$HOME/Development/other.dir" > /dev/null
EDITOR=cat gws_in "$HOME/Development/other.dir" edit
expect_out "dir = ~/Development/other.dir" "edit picks the project of the current dir"
FAKE_FZF_OUTPUT=app EDITOR=cat gws_in "$WORK" edit
expect_file "$FAKE_FZF_INPUT" "second" "edit offers projects in the picker"
expect_out "[editor]" "edit opens the picked project"
FAKE_FZF_EXIT=130 EDITOR=cat gws_in "$WORK" edit
if [ -z "$out" ] && [ "$code" = 0 ]; then ok; else bad "edit with a cancelled picker does nothing"; fi

# --- delete -------------------------------------------------------------------------

sessions "$(session_line app.2 0 "$APP")" "$(session_line second.shell 0 /tmp)"
gws delete app.2
expect_code 1 "delete pane without --yes"
expect_out "rerun with --yes" "delete pane without --yes"
expect_file "$PROJECTS/app.ini" "[2]" "delete without --yes keeps the pane"

gws delete app.2 --yes
expect_code 0 "delete pane"
expect_out "deleted app.2" "delete pane"
expect_no_file_text "$PROJECTS/app.ini" "[2]" "delete pane removes its section"
expect_file "$PROJECTS/app.ini" "[server]" "delete pane keeps the others"
expect_file "$FAKE_LOG" "zmx kill app.2" "delete pane kills its session"

gws delete app.3 --yes
expect_no_file_text "$FAKE_LOG" "zmx kill" "delete a stopped pane kills nothing"
gws delete app.nope --yes
expect_code 1 "delete unknown pane"
expect_out 'pane "app.nope" not found' "delete unknown pane"
gws delete ghost --yes
expect_code 1 "delete unknown project"
expect_out 'project "ghost" not found' "delete unknown project"

gws delete second
expect_code 1 "delete project without --yes"
expect_file "$PROJECTS/second.ini" "dir" "delete without --yes keeps the file"
gws delete second --yes
expect_code 0 "delete project"
if [ ! -e "$PROJECTS/second.ini" ]; then ok; else bad "delete project removes the file"; fi
expect_file "$FAKE_LOG" "zmx kill second.shell" "delete project kills its sessions"

# --- config -------------------------------------------------------------------------

printf 'color = red\n' > "$XDG_CONFIG_HOME/gws/config.ini"
gws list
expect_code 1 "invalid config"
expect_out "config.ini: line 1: unknown key \"color\"" "invalid config"
rm "$XDG_CONFIG_HOME/gws/config.ini"

rm "$WORK/bin/zmx"
gws list
expect_code 1 "zmx missing"
expect_out "zmx not found in PATH" "zmx missing"

echo "cli: $passed passed, $failed failed"
[ "$failed" = 0 ]
