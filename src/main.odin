package gws

import "core:os"
import "core:slice"
import "core:strings"

USAGE :: `gws - Ghostty workspaces on zmx sessions

Usage:
  gws                              pick a session, project, pane or directory (fzf)
  gws pick [--kill]                same; --kill picks a session to kill
  gws new <name> [dir]             create a project (dir defaults to $PWD)
  gws edit [name]                  edit a project file in $EDITOR
  gws attach <name>[.<pane>]       attach here; creates the pane if missing
  gws attach <dir>                 attach a session named after dir (., ./x, ~/x, /x)
  gws open [name] [--force]        open the project layout (here, or new tabs inside zmx)
  gws split [right|left|down|up]   split this pane with a new project pane
  gws tab                          open a new project pane in a new tab
  gws list                         list projects and sessions
  gws kill [name[.pane]]           kill a project, pane or session (default: current)
  gws delete <name>[.<pane>] --yes kill a project or pane and remove it from its file
  gws help                         show this help

Omitted [name]: the project of this directory, else pick one with fzf.

Projects: ~/.config/gws/projects/<name>.ini
Config:   ~/.config/gws/config.ini
Detach:   ctrl+\
`

Args :: struct {
	pos:   [dynamic]string,
	flags: map[string]bool,
}

parse_args :: proc(rest: []string, allowed: ..string) -> Args {
	a: Args
	for arg in rest {
		if strings.has_prefix(arg, "--") {
			if !slice.contains(allowed, arg) {
				fail("unknown option ", arg)
			}
			a.flags[arg] = true
		} else {
			append(&a.pos, arg)
		}
	}
	return a
}

usage_error :: proc(line: string) -> ! {
	os.write_string(os.stderr, cat("usage: ", line, "\n"))
	os.exit(2)
}

// "" when the picker is cancelled.
project_arg :: proc(a: Args, usage: string) -> string {
	switch len(a.pos) {
	case 0:
		return pick_project()
	case 1:
		return a.pos[0]
	}
	usage_error(usage)
}

abs_dir :: proc(arg: string) -> string {
	expanded := expand_home(arg)
	defer delete(expanded)

	dir, e := os.get_absolute_path(expanded, context.allocator)
	if e != nil || !os.is_dir(dir) {
		fail("not a directory: ", arg)
	}
	return dir
}

main :: proc() {
	a: Args
	defer delete_args(&a)

	args := os.args[1:]
	if len(args) == 0 {
		cmd_pick(false)
		return
	}

	rest := args[1:]
	switch args[0] {
	case "pick":
		a = parse_args(rest, "--kill")
		cmd_pick(a.flags["--kill"])
	case "new":
		a = parse_args(rest)
		cmd_new(a)
	case "edit":
		a = parse_args(rest)
		cmd_edit(a)
	case "attach":
		a = parse_args(rest)
		cmd_attach(a)
	case "open":
		a = parse_args(rest, "--force")
		cmd_open(a)
	case "split":
		a = parse_args(rest)
		cmd_split(a)
	case "tab":
		if len(rest) > 0 {
			usage_error("gws tab")
		}
		g := load_global()
		defer delete_global(&g)
		add_pane(g, "")
	case "list":
		cmd_list()
	case "kill":
		a = parse_args(rest)
		cmd_kill(a)
	case "delete":
		a = parse_args(rest, "--yes")
		cmd_delete(a)
	case "help", "-h", "--help":
		os.write_string(os.stdout, USAGE)
	case:
		os.write_string(os.stderr, cat("gws: unknown command ", quote(args[0]), "\n\n", USAGE))
		os.exit(2)
	}
}

cmd_new :: proc(a: Args) {
	if len(a.pos) < 1 || len(a.pos) > 2 {
		usage_error("gws new <name> [dir]")
	}
	name := a.pos[0]
	if !valid_name(name) {
		fail("invalid project name ", quote(name), " (use A-Z a-z 0-9 _ -)")
	}
	if project_exists(name) {
		fail("project ", quote(name), " already exists (gws edit ", name, ")")
	}
	dir := abs_dir(a.pos[1] if len(a.pos) == 2 else ".")
	defer delete(dir)

	if e := os.make_directory_all(projects_dir()); e != nil && e != .Exist {
		fail("cannot create ", projects_dir(), ": ", os.error_string(e))
	}
	path := project_path(name)

	text := new_project_text(collapse_home(dir))
	defer delete(text)

	if e := os.write_entire_file(path, text); e != nil {
		fail("cannot write ", path, ": ", os.error_string(e))
	}
	say("created ", collapse_home(path))
}

cmd_edit :: proc(a: Args) {
	name := project_arg(a, "gws edit [name]")
	if name == "" {
		return
	}
	if !project_exists(name) {
		fail("project ", quote(name), " not found")
	}
	exec_cmd({"/bin/sh", "-c", `exec ${EDITOR:-vi} "$1"`, "sh", project_path(name)})
}

cmd_attach :: proc(a: Args) {
	if len(a.pos) != 1 {
		usage_error("gws attach <name>[.<pane>] | <dir>")
	}

	target := a.pos[0]
	// Names cannot contain these, so a path is never mistaken for a session.
	if strings.contains(target, "/") ||
	   strings.has_prefix(target, ".") ||
	   strings.has_prefix(target, "~") {
		attach_dir(abs_dir(target))
	}

	attach_target(target, load_global())
}

// Target is "project", "project.pane", or any live zmx session name.
attach_target :: proc(target: string, g: Global) -> ! {
	project, pane_name, has_pane := split_session(target)
	if project_exists(project) {
		p := load_project(project, g)
		if !has_pane && len(p.panes) > 0 {
			pane_name = p.panes[0].name
		}
		if pane, ok := find_pane(p, pane_name); ok {
			attach_here(session_name(p.name, pane.name), pane.dir, pane.cmd)
		}
	}
	if _, live := find_session(zmx_sessions()[:], target); live {
		attach_here(target, "", "")
	}
	fail("no project pane or session named ", quote(target))
}

cmd_open :: proc(a: Args) {
	name := project_arg(a, "gws open [name] [--force]")
	if name == "" {
		return
	}
	open_project(name, a.flags["--force"])
}

open_project :: proc(name: string, force: bool) {
	require_macos("open")

	g := load_global()
	defer delete_global(&g)

	p := load_project(name, g)
	defer delete_project(&p)

	if len(p.panes) == 0 {
		fail("project ", quote(p.name), " has no panes (gws edit ", p.name, ")")
	}
	sessions := zmx_sessions()
	defer {
		for &s in sessions {
			delete(s.dir)
		}
		delete(sessions)
	}
	for pane in p.panes {
		if !os.is_dir(pane.dir) {
			fail(p.name, ".", pane.name, ": not a directory: ", pane.dir)
		}
		s, ok := find_session(sessions[:], session_name(p.name, pane.name))
		if ok && s.clients > 0 && !force {
			fail(
				p.name,
				" is already open (",
				s.name,
				" is attached); use --force to open another view",
			)
		}
	}
	here := ghostty_tty()

	script := build_open_script(p, here)
	defer delete(script)

	err := run_applescript(script)
	if err != "" {
		fail(err)
	}

	if here != "" {
		first := p.panes[0]
		attach_here(session_name(p.name, first.name), first.dir, first.cmd)
	}
	say("opened ", p.name)
}

cmd_split :: proc(a: Args) {
	if len(a.pos) > 1 {
		usage_error("gws split [right|left|down|up]")
	}
	g := load_global()
	defer delete_global(&g)

	direction := a.pos[0] if len(a.pos) == 1 else g.split
	if !valid_split(direction) {
		fail("split must be right, left, down or up")
	}
	add_pane(g, direction)
}

// Adds a pane next to the current one, or in a new tab when direction is "".
add_pane :: proc(g: Global, direction: string) {
	require_macos("split" if direction != "" else "tab")
	current := get_env("ZMX_SESSION")
	defer delete(current)

	if current == "" {
		fail("not inside a zmx session")
	}

	project, pane_name, _ := split_session(current)
	if !project_exists(project) {
		fail("session ", quote(current), " is not part of a gws project")
	}

	p := load_project(project, g)
	defer delete_project(&p)

	pane := Pane {
		tab   = "main",
		dir   = p.dir,
		split = direction,
	}
	if cur, ok := find_pane(p, pane_name); ok {
		pane.tab, pane.dir = cur.tab, cur.dir
		if direction != "" {
			pane.from = cur.name
		}
	}

	sessions := zmx_sessions()
	defer {
		for &s in sessions {
			delete(s.dir)
		}
		delete(sessions)
	}

	for n := 2;; n += 1 {
		candidate := itoa(n)

		_, taken := find_pane(p, candidate)
		if _, live := find_session(sessions[:], session_name(p.name, candidate)); live {
			taken = true
		}
		for q in p.panes {
			if q.tab == candidate {
				taken = true
			}
		}

		if !taken {
			pane.name = candidate
			break
		}
		delete(candidate)
	}
	defer delete(pane.name)

	before := ""
	if direction == "" {
		before = next_tab_pane(p, pane.tab)
		pane.tab = pane.name
	}
	// The new pane runs `gws attach`, which reads the file, so write it first.
	original, e := os.read_entire_file(p.path, context.allocator)
	if e != nil {
		fail("cannot read ", p.path, ": ", os.error_string(e))
	}
	defer delete(original)

	if e := insert_pane(p, pane, before); e != nil {
		fail("cannot update ", p.path, ": ", os.error_string(e))
	}

	session := session_name(p.name, pane.name)
	script := build_add_script(session, pane)
	defer delete(script)

	if err := run_applescript(script); err != "" {
		_ = os.write_entire_file(p.path, string(original))
		fail(err)
	}
	say("added ", session, " (", direction if direction != "" else "tab", ")")
}

cmd_list :: proc() {
	g := load_global()
	defer delete_global(&g)

	sessions := zmx_sessions()
	defer {
		for &s in sessions {
			delete(s.dir)
		}
		delete(sessions)
	}

	names := project_names()
	defer delete(names)

	claimed: map[string]bool
	defer delete(claimed)

	if len(names) > 0 {
		say(pad("PROJECT", 20), pad("PANES", 7), "DIR")
		for name in names {
			p, err := try_load_project(name, g)
			defer delete_project(&p)
			defer delete(err)

			if err != "" {
				say(pad(name, 20), pad("error", 7), err)
				continue
			}
			live := 0
			for pane in p.panes {
				sn := session_name(p.name, pane.name)
				claimed[sn] = true
				if _, ok := find_session(sessions[:], sn); ok {
					live += 1
				}
			}

			{
				live_text := itoa(live)
				total_text := itoa(len(p.panes))
				counts := cat(live_text, "/", total_text)

				defer delete(live_text)
				defer delete(total_text)
				defer delete(counts)

				say(pad(name, 20), pad(counts, 7), collapse_home(p.dir))
			}
		}
	}

	others: [dynamic]Session
	defer delete(others)

	for s in sessions {
		if !claimed[s.name] {
			append(&others, s)
		}
	}
	if len(others) > 0 {
		if len(names) > 0 {
			say()
		}
		say(pad("SESSION", 20), pad("CLIENTS", 7), "DIR")
		for s in others {
			clients := itoa(s.clients)
			defer delete(clients)
			say(pad(s.name, 20), pad(clients, 7), collapse_home(s.dir))
		}
	}
	if len(names) == 0 && len(others) == 0 {
		say("no projects or sessions (create one: gws new <name>)")
	}
}

cmd_kill :: proc(a: Args) {
	if len(a.pos) > 1 {
		usage_error("gws kill [name[.pane]]")
	}
	if len(a.pos) == 0 {
		current := get_env("ZMX_SESSION")
		defer delete(current)

		if current == "" {
			usage_error("gws kill [name[.pane]]  (no argument: current zmx session)")
		}
		kill_sessions({current})
		return
	}
	target := a.pos[0]
	sessions := zmx_sessions()
	defer {
		for &s in sessions {
			delete(s.dir)
		}
		delete(sessions)
	}

	if project_exists(target) {
		names := project_sessions(target, sessions[:])
		defer delete(names)

		if len(names) > 0 {
			kill_sessions(names)
			return
		}
	}
	if _, live := find_session(sessions[:], target); !live {
		fail("no live session or project panes named ", quote(target))
	}
	kill_sessions({target})
}

// The file changes before the kill, which may end this process when run from the pane.
cmd_delete :: proc(a: Args) {
	if len(a.pos) != 1 {
		usage_error("gws delete <name>[.<pane>] --yes")
	}
	target := a.pos[0]
	name, pane_name, has_pane := split_session(target)
	if !project_exists(name) {
		fail("project ", quote(name), " not found")
	}
	if has_pane {
		g := load_global()
		defer delete_global(&g)

		p := load_project(name, g)
		defer delete_project(&p)

		if _, ok := find_pane(p, pane_name); !ok {
			fail("pane ", quote(target), " not found")
		}
		if !a.flags["--yes"] {
			fail(
				"this kills ",
				target,
				" and removes it from ",
				collapse_home(p.path),
				"; rerun with --yes",
			)
		}

		data, e := os.read_entire_file(p.path, context.allocator)
		if e != nil {
			fail("cannot read ", p.path, ": ", os.error_string(e))
		}
		defer delete(data)

		updated := remove_section(string(data), pane_name)
		defer delete(updated)

		if e = os.write_entire_file(p.path, updated); e != nil {
			fail("cannot update ", p.path, ": ", os.error_string(e))
		}
		say("deleted ", target)

		sessions := zmx_sessions()
		if _, live := find_session(sessions[:], target); live {
			// Keep sessions alive until kill_sessions has finished.
			kill_sessions({target})
		}
		for &s in sessions {
			delete(s.dir)
		}
		delete(sessions)

		return
	}
	if !a.flags["--yes"] {
		fail("this kills all panes of ", name, " and removes its file; rerun with --yes")
	}
	path := project_path(name)
	if e := os.remove(path); e != nil {
		fail("cannot remove ", path, ": ", os.error_string(e))
	}
	say("deleted ", collapse_home(path))

	sessions := zmx_sessions()
	names := project_sessions(name, sessions[:])

	if len(names) > 0 {
		kill_sessions(names)
	}

	delete(names)
	for &s in sessions {
		delete(s.dir)
	}
	delete(sessions)
}

delete_args :: proc(a: ^Args) {
	delete(a.pos)
	delete(a.flags)
	a^ = {}
}
