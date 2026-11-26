package gws

import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Session :: struct {
	name:    string,
	pid:     int,
	clients: int,
	dir:     string,
}

// Listing.

// One session per line: tab-separated key=value fields; the current one is prefixed "→ ".
// Unreachable sessions (err=) are left out. `ended` is a finished `zmx run` task and
// `status` may be a label: both describe live sessions.
parse_zmx_list :: proc(output: string) -> []Session {
	sessions: [dynamic]Session
	rest := output
	for raw_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_left_space(strings.trim_prefix(strings.trim_left_space(raw_line), "→"))
		session: Session
		dead := false
		for field in strings.split_iterator(&line, "\t") {
			key, _, value := strings.partition(field, "=")
			switch key {
			case "name":
				session.name = value
			case "pid":
				session.pid, _ = strconv.parse_int(value)
			case "clients":
				session.clients, _ = strconv.parse_int(value)
			case "cwd":
				session.dir = cwd_url_to_path(value)
			case "err":
				dead = true
			}
		}
		if !dead && session.name != "" {
			append(&sessions, session)
		}
	}
	return sessions[:]
}

// "file://host/Users/me/a%20b" -> "/Users/me/a b"
cwd_url_to_path :: proc(url: string) -> string {
	path := strings.trim_prefix(url, "file://")
	if i := strings.index_byte(path, '/'); i >= 0 {
		path = path[i:]
	}
	if decoded, ok := net.percent_decode(path); ok {
		return decoded
	}
	return path
}

live_sessions :: proc() -> []Session {
	result := run_process({"zmx", "list"})
	if !result.started {
		fail("zmx not found in PATH")
	}
	return parse_zmx_list(result.stdout)
}

find_session :: proc(sessions: []Session, name: string) -> (Session, bool) {
	for session in sessions {
		if session.name == name {
			return session, true
		}
	}
	return {}, false
}

is_session_live :: proc(sessions: []Session, name: string) -> bool {
	_, found := find_session(sessions, name)
	return found
}

// The session of a `zmx attach <session> ...` command line, else "".
attach_command_session :: proc(args: []string) -> string {
	if len(args) < 3 || os.base(args[0]) != "zmx" || args[1] != "attach" && args[1] != "a" {
		return ""
	}
	return "" if strings.has_prefix(args[2], "-") else args[2]
}

// Live sessions of the project, named "<project>.<pane>".
project_sessions :: proc(project_name: string, sessions: []Session) -> []string {
	prefix := concat(project_name, ".")
	names: [dynamic]string
	for session in sessions {
		if strings.has_prefix(session.name, prefix) {
			append(&names, session.name)
		}
	}
	return names[:]
}

// Attaching and creating.

// target is "project" (its first pane), "project.pane", or any live session name.
attach_target :: proc(target: string, config: Config) -> ! {
	project_name, pane_name, has_pane := split_session_name(target)
	if project_exists(project_name) {
		project := load_project(project_name, config)
		if !has_pane && len(project.panes) > 0 {
			pane_name = project.panes[0].name
		}
		if pane, found := find_pane(project, pane_name); found {
			attach_session(session_name(project.name, pane.name), pane.dir, pane.cmd)
		}
	}
	if is_session_live(live_sessions(), target) {
		attach_session(target, "", "")
	}
	fail("no project pane or session named ", quoted(target))
}

// A session named after the directory, started in it.
attach_dir :: proc(dir: string) -> ! {
	name := sanitize_name(os.base(dir))
	if !is_valid_name(name) {
		fail("cannot derive a session name from ", dir)
	}
	attach_session(name, dir, "")
}

// Attaches this terminal to session, creating it in dir with cmd when it does not exist.
attach_session :: proc(session, dir, cmd: string) -> ! {
	if dir != "" && !os.is_dir(dir) {
		fail(session, ": not a directory: ", dir)
	}
	set_terminal_title(session)

	if get_env("ZMX_SESSION") != "" {
		// Inside a session `zmx attach` only switches the client and drops the command.
		if !is_session_live(live_sessions(), session) {
			create_detached_session(session, dir, cmd)
		}
		replace_process({"zmx", "attach", session})
	}

	if dir != "" {
		if err := os.set_working_directory(dir); err != nil {
			fail("cannot cd to ", dir, ": ", os.error_string(err))
		}
	}
	replace_process(attach_command(session, cmd))
}

set_terminal_title :: proc(title: string) {
	os.write_string(os.stdout, concat("\x1b]0;", title, "\a"))
}

// zmx ignores the command when the session already exists.
attach_command :: proc(session, cmd: string) -> []string {
	command: [dynamic]string
	append(&command, "zmx", "attach", session)
	if cmd != "" {
		append(&command, "/bin/sh", "-c", PANE_SCRIPT, shell_path(), cmd)
	}
	return command[:]
}

// attach_command without a terminal: zmx creates the session and returns at EOF on
// stdin (run_process gives it /dev/null). Without ZMX_SESSION it creates the session
// instead of switching this one.
create_detached_session :: proc(session, dir, cmd: string) {
	env, _ := os.environ(context.allocator)
	env = slice.filter(env, proc(entry: string) -> bool {
		return !strings.has_prefix(entry, "ZMX_SESSION=")
	})
	if result := run_process(attach_command(session, cmd), dir, env); !result.ok {
		fail("cannot create session ", session, ": ", strings.trim_space(result.stderr))
	}
}

// Run by /bin/sh with the user's shell as $0 and the pane's cmd as $1: the shell runs cmd,
// then the session drops back to an interactive shell when cmd exits or on ctrl+c, so it
// stays alive. sh holds the trap: not every shell has one.
PANE_SCRIPT :: `trap 'exec "$0"' INT; "$0" -c "$1"; exec "$0"`

// Killing the current session hangs up this process and zmx with it, and zmx kills in
// its own order, so the current one is killed last, on its own.
kill_sessions :: proc(names: []string) {
	print_line("killing ", strings.join(names, " "))
	current := get_env("ZMX_SESSION")
	others: [dynamic]string
	for name in names {
		if name != current {
			append(&others, name)
		}
	}
	if len(others) > 0 {
		zmx_kill(others[:])
	}
	if len(others) < len(names) {
		zmx_kill({current})
	}
}

zmx_kill :: proc(names: []string) {
	command: [dynamic]string
	append(&command, "zmx", "kill")
	append(&command, ..names)
	if result := run_process(command[:]); !result.ok {
		fail(strings.trim_space(result.stderr))
	}
}
