package gws

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"

// Set by `make` and the release build from the git tag: -define:GWS_VERSION=1.2.3
GWS_VERSION :: #config(GWS_VERSION, "dev")

USAGE :: `gws - Ghostty workspaces on zmx sessions

Usage:
  gws                              pick a session, project, pane or directory (fzf)
  gws pick [--kill]                same; --kill picks a session to kill
  gws new <name> [dir]             create a project (dir defaults to $PWD)
  gws edit [name]                  edit a project file in $EDITOR
  gws attach <name>[.<pane>]       attach here; creates the pane if missing
  gws attach <dir>                 attach a session named after dir (., ./x, ~/x, /x)
  gws open [name] [--force]        open the project layout, or the panes not open elsewhere
  gws split [where [name]]         split this pane with a new project pane
                                   (where: right, left, down, up)
  gws tab [name]                   open a new project pane in a new tab
  gws list                         list projects and sessions
  gws kill [name[.pane]]           kill a project, pane or session (default: current)
  gws delete <name>[.<pane>] --yes kill a project or pane and remove it from its file
  gws help                         show this help
  gws version                      show the version (also -v, --version)

Omitted [name]: the project of this directory, else pick one with fzf.

Projects: ~/.config/gws/projects/<name>.ini
Config:   ~/.config/gws/config.ini
Detach:   ctrl+\
`

// Every allocation goes to one arena, released when main returns. Commands that exit
// early (fail, replace_process) leave that to the OS. Nothing is freed one by one.
main :: proc() {
	arena: runtime.Arena
	context.allocator = runtime.arena_allocator(&arena)
	defer runtime.arena_destroy(&arena)

	dispatch(os.args[1:])
}

dispatch :: proc(argv: []string) {
	if len(argv) == 0 {
		cmd_pick(false)
		return
	}
	rest := argv[1:]
	switch argv[0] {
	case "pick":
		args := parse_args(rest, "--kill")
		if len(args.positional) > 0 {
			usage_error("gws pick [--kill]")
		}
		cmd_pick(args.flags["--kill"])
	case "new":
		cmd_new(parse_args(rest))
	case "edit":
		cmd_edit(parse_args(rest))
	case "attach":
		cmd_attach(parse_args(rest))
	case "open":
		cmd_open(parse_args(rest, "--force"))
	case "split":
		cmd_split(parse_args(rest))
	case "tab":
		cmd_tab(parse_args(rest))
	case "list":
		if len(parse_args(rest).positional) > 0 {
			usage_error("gws list")
		}
		cmd_list()
	case "kill":
		cmd_kill(parse_args(rest))
	case "delete":
		cmd_delete(parse_args(rest, "--yes"))
	case "help", "-h", "--help":
		os.write_string(os.stdout, USAGE)
	case "version", "-v", "--version":
		print_line("gws ", GWS_VERSION)
	case:
		os.write_string(os.stderr, concat("gws: unknown command ", quoted(argv[0]), "\n\n", USAGE))
		os.exit(2)
	}
}

Args :: struct {
	positional: [dynamic]string,
	flags:      map[string]bool,
}

// Exits on a flag not in allowed.
parse_args :: proc(argv: []string, allowed: ..string) -> Args {
	args: Args
	for arg in argv {
		if !strings.has_prefix(arg, "--") {
			append(&args.positional, arg)
		} else if slice.contains(allowed, arg) {
			args.flags[arg] = true
		} else {
			fail("unknown option ", arg)
		}
	}
	return args
}

usage_error :: proc(usage: string) -> ! {
	os.write_string(os.stderr, concat("usage: ", usage, "\n"))
	os.exit(2)
}

// The named project, or one picked for the current directory; "" when the picker is cancelled.
project_name_arg :: proc(args: Args, usage: string) -> string {
	switch len(args.positional) {
	case 0:
		return pick_project()
	case 1:
		return args.positional[0]
	}
	usage_error(usage)
}

cmd_new :: proc(args: Args) {
	if len(args.positional) < 1 || len(args.positional) > 2 {
		usage_error("gws new <name> [dir]")
	}
	name := args.positional[0]
	if !is_valid_name(name) {
		fail("invalid project name ", quoted(name), NAME_RULE)
	}
	if project_exists(name) {
		fail("project ", quoted(name), " already exists (gws edit ", name, ")")
	}
	dir := resolve_dir(args.positional[1] if len(args.positional) == 2 else ".")

	if err := os.make_directory_all(projects_dir()); err != nil && err != .Exist {
		fail("cannot create ", projects_dir(), ": ", os.error_string(err))
	}
	path := project_path(name)
	write_file(path, new_project_text(collapse_home(dir)))
	print_line("created ", collapse_home(path))
}

cmd_edit :: proc(args: Args) {
	name := project_name_arg(args, "gws edit [name]")
	if name == "" {
		return
	}
	if !project_exists(name) {
		fail("project ", quoted(name), " not found")
	}
	replace_process({"/bin/sh", "-c", `exec ${EDITOR:-vi} "$1"`, "sh", project_path(name)})
}

cmd_attach :: proc(args: Args) {
	if len(args.positional) != 1 {
		usage_error("gws attach <name>[.<pane>] | <dir>")
	}
	target := args.positional[0]
	// Names cannot contain these, so a path is never mistaken for a session.
	if strings.contains(target, "/") ||
	   strings.has_prefix(target, ".") ||
	   strings.has_prefix(target, "~") {
		attach_dir(resolve_dir(target))
	}
	attach_target(target, load_config())
}

cmd_open :: proc(args: Args) {
	require_macos("open")
	name := project_name_arg(args, "gws open [name] [--force]")
	if name == "" {
		return
	}
	open_project(name, args.flags["--force"])
}

// Builds the project's Ghostty layout. From a plain Ghostty terminal the first tab is
// built there and this process attaches its first pane. Panes attached elsewhere stay
// where they are; only the others open, unless force opens them all.
open_project :: proc(name: string, force: bool) {
	require_macos("open")
	project := load_project(name, load_config())
	if len(project.panes) == 0 {
		fail("project ", quoted(project.name), " has no panes (gws edit ", project.name, ")")
	}

	sessions := live_sessions()
	unattached: [dynamic]Pane
	for pane in project.panes {
		if !os.is_dir(pane.dir) {
			fail(project.name, ".", pane.name, ": not a directory: ", pane.dir)
		}
		session, live := find_session(sessions, session_name(project.name, pane.name))
		if force || !live || session.clients == 0 {
			append(&unattached, pane)
		}
	}
	if len(unattached) == 0 {
		fail(project.name, " is already open; use --force to open another view")
	}
	pane_count := len(project.panes)
	project.panes = unattached

	here_tty := current_ghostty_tty()
	if err := run_applescript(open_layout_script(project, here_tty)); err != "" {
		fail(err)
	}
	if len(unattached) == pane_count {
		print_line("opened ", project.name)
	} else {
		print_line(
			"opened ", project.name, " (", int_to_string(len(unattached)), " of ",
			int_to_string(pane_count), " panes; the rest are open elsewhere)",
		)
	}
	if here_tty != "" {
		first := project.panes[0]
		attach_session(session_name(project.name, first.name), first.dir, first.cmd)
	}
}

// A name needs an explicit direction first, so a mistyped direction is not taken as a name.
cmd_split :: proc(args: Args) {
	require_macos("split")
	if len(args.positional) > 2 {
		usage_error("gws split [right|left|down|up [name]]")
	}
	config := load_config()
	direction := args.positional[0] if len(args.positional) >= 1 else config.default_split
	if !is_valid_split(direction) {
		fail(SPLIT_ERROR)
	}
	add_pane(config, direction, args.positional[1] if len(args.positional) == 2 else "")
}

cmd_tab :: proc(args: Args) {
	require_macos("tab")
	if len(args.positional) > 1 {
		usage_error("gws tab [name]")
	}
	add_pane(load_config(), "", args.positional[0] if len(args.positional) == 1 else "")
}

// Adds a pane next to the current one, or in a new tab when direction is "". Without a
// name the pane is numbered.
add_pane :: proc(config: Config, direction, name: string) {
	current_session := get_env("ZMX_SESSION")
	if current_session == "" {
		fail("not inside a zmx session")
	}
	project_name, current_pane_name, _ := split_session_name(current_session)
	if !project_exists(project_name) {
		fail("session ", quoted(current_session), " is not part of a gws project")
	}
	project := load_project(project_name, config)

	sessions := live_sessions()
	pane_name := name
	if pane_name == "" {
		pane_name = next_pane_name(project, sessions)
	} else if !is_valid_name(pane_name) {
		fail("invalid pane name ", quoted(pane_name), NAME_RULE)
	} else if !is_pane_name_free(project, sessions, pane_name) {
		fail(quoted(pane_name), " is already a pane, tab or session of ", project.name)
	}
	pane := Pane {
		name  = pane_name,
		tab   = "main",
		dir   = project.dir,
		split = direction,
	}
	if current_pane, found := find_pane(project, current_pane_name); found {
		pane.tab, pane.dir = current_pane.tab, current_pane.dir
		if direction != "" {
			pane.from = current_pane.name
		}
	}
	insert_before := ""
	if direction == "" {
		insert_before = first_pane_of_next_tab(project, pane.tab)
		pane.tab = pane.name
	}

	// The new pane runs `gws attach`, which reads the file, so write it first.
	original := read_file(project.path)
	write_file(project.path, insert_section(original, pane_section(project, pane), insert_before))

	session := session_name(project.name, pane.name)
	if err := run_applescript(add_pane_script(session, pane)); err != "" {
		write_file(project.path, original)
		fail(err)
	}
	print_line("added ", session, " (", direction if direction != "" else "tab", ")")
}

cmd_list :: proc() {
	config := load_config()
	sessions := live_sessions()
	names := project_names()
	project_session_names: map[string]bool

	if len(names) > 0 {
		print_line(pad_right("PROJECT", 20), pad_right("PANES", 7), "DIR")
	}
	for name in names {
		project, err := try_load_project(name, config)
		if err != "" {
			print_line(pad_right(name, 20), pad_right("error", 7), err)
			continue
		}
		live := 0
		for pane in project.panes {
			session := session_name(project.name, pane.name)
			project_session_names[session] = true
			if is_session_live(sessions, session) {
				live += 1
			}
		}
		counts := concat(int_to_string(live), "/", int_to_string(len(project.panes)))
		print_line(pad_right(name, 20), pad_right(counts, 7), collapse_home(project.dir))
	}

	others: [dynamic]Session
	for session in sessions {
		if !project_session_names[session.name] {
			append(&others, session)
		}
	}
	if len(others) > 0 {
		if len(names) > 0 {
			print_line()
		}
		print_line(pad_right("SESSION", 20), pad_right("CLIENTS", 7), "DIR")
		for session in others {
			print_line(pad_right(session.name, 20), pad_right(int_to_string(session.clients), 7), collapse_home(session.dir))
		}
	}
	if len(names) == 0 && len(others) == 0 {
		print_line("no projects or sessions (create one: gws new <name>)")
	}
}

cmd_kill :: proc(args: Args) {
	if len(args.positional) > 1 {
		usage_error("gws kill [name[.pane]]")
	}
	if len(args.positional) == 0 {
		current_session := get_env("ZMX_SESSION")
		if current_session == "" {
			usage_error("gws kill [name[.pane]]  (no argument: current zmx session)")
		}
		kill_sessions({current_session})
		return
	}

	target := args.positional[0]
	sessions := live_sessions()
	if project_exists(target) {
		if names := project_sessions(target, sessions); len(names) > 0 {
			kill_sessions(names)
			return
		}
	}
	if !is_session_live(sessions, target) {
		fail("no live session or project panes named ", quoted(target))
	}
	kill_sessions({target})
}

// The file changes before the kill, which may end this process when run from the pane.
cmd_delete :: proc(args: Args) {
	if len(args.positional) != 1 {
		usage_error("gws delete <name>[.<pane>] --yes")
	}
	target := args.positional[0]
	project_name, pane_name, has_pane := split_session_name(target)
	if !project_exists(project_name) {
		fail("project ", quoted(project_name), " not found")
	}
	confirmed := args.flags["--yes"]

	if has_pane {
		project := load_project(project_name, load_config())
		if _, found := find_pane(project, pane_name); !found {
			fail("pane ", quoted(target), " not found")
		}
		if !confirmed {
			fail("this kills ", target, " and removes it from ", collapse_home(project.path), "; rerun with --yes")
		}
		write_file(project.path, remove_section(read_file(project.path), pane_name))
		print_line("deleted ", target)
		if is_session_live(live_sessions(), target) {
			kill_sessions({target})
		}
		return
	}

	if !confirmed {
		fail("this kills all panes of ", project_name, " and removes its file; rerun with --yes")
	}
	path := project_path(project_name)
	if err := os.remove(path); err != nil {
		fail("cannot remove ", path, ": ", os.error_string(err))
	}
	print_line("deleted ", collapse_home(path))
	if names := project_sessions(project_name, live_sessions()); len(names) > 0 {
		kill_sessions(names)
	}
}
