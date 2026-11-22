package gws

import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

Session :: struct {
	name:    string,
	clients: int,
	dir:     string,
}

// Listing.

// One session per line: tab-separated key=value fields; the current one is prefixed "→ ".
// Sessions that errored or ended are left out.
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
			case "clients":
				session.clients, _ = strconv.parse_int(value)
			case "cwd":
				session.dir = cwd_url_to_path(value)
			case "err", "status", "ended":
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
	if cmd == "" {
		replace_process({"zmx", "attach", session})
	}
	// zmx ignores the command when the session already exists.
	replace_process({"zmx", "attach", session, shell_path(), "-c", pane_script(cmd)})
}

set_terminal_title :: proc(title: string) {
	os.write_string(os.stdout, concat("\x1b]0;", title, "\a"))
}
// `zmx run -d` quotes each argument and types the line into a bash prompt;
// `exec` replaces bash, so zmx's task marker never runs.
create_detached_session :: proc(session, dir, cmd: string) {
	command: [dynamic]string
	append(&command, "zmx", "run", session, "-d", "exec", shell_path())
	if cmd == "" {
		append(&command, "-l")
	} else {
		append(&command, "-c", concat("clear\n", pane_script(cmd)))
	}
	if result := run_process(command[:], dir); !result.ok {
		fail("cannot create session ", session, ": ", strings.trim_space(result.stderr))
	}
}

// Shell script that runs cmd, then drops back to an interactive shell when cmd exits or
// on ctrl+c, so the session stays alive.
pane_script :: proc(cmd: string) -> string {
	shell := shell_path()
	// Newlines, not ';': cmd may end with '&' or a '#' comment.
	return concat("trap \"exec ", shell_quote(shell), "\" INT\n", cmd, "\nexec ", shell)
}

kill_sessions :: proc(names: []string) {
	print_line("killing ", strings.join(names, " "))
	command: [dynamic]string
	append(&command, "zmx", "kill")
	append(&command, ..names)
	if result := run_process(command[:]); !result.ok {
		fail(strings.trim_space(result.stderr))
	}
}
