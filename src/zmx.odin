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

// One session per line: tab-separated key=value fields; the current one is prefixed "→ ".
parse_zmx_list :: proc(out: string) -> [dynamic]Session {
	sessions: [dynamic]Session
	rest := out
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_left_space(strings.trim_prefix(strings.trim_left_space(raw), "→"))
		s: Session
		dead := false
		for field in strings.split_iterator(&line, "\t") {
			key, _, value := strings.partition(field, "=")
			switch key {
			case "name":
				s.name = value
			case "clients":
				s.clients, _ = strconv.parse_int(value)
			case "cwd":
				s.dir = decode_cwd(value)
			case "err", "status", "ended":
				dead = true
			}
		}
		if !dead && s.name != "" {
			append(&sessions, s)
		}
	}
	return sessions
}

// "file://host/Users/me/a%20b" -> "/Users/me/a b"
decode_cwd :: proc(v: string) -> string {
	path := strings.trim_prefix(v, "file://")
	if i := strings.index_byte(path, '/'); i >= 0 {
		path = path[i:]
	}
	decoded, ok := net.percent_decode(path)
	return decoded if ok else path
}

zmx_sessions :: proc() -> [dynamic]Session {
	r := run({"zmx", "list"})
	if !r.started {
		fail("zmx not found in PATH")
	}
	return parse_zmx_list(r.out)
}

find_session :: proc(sessions: []Session, name: string) -> (Session, bool) {
	for s in sessions {
		if s.name == name {
			return s, true
		}
	}
	return {}, false
}

// Drops back to an interactive shell when cmd exits or on ctrl+c, so the session stays alive.
pane_wrapper :: proc(cmd: string) -> string {
	sh := shell_quote(shell_path())
	// Newlines, not ';': cmd may end with '&' or a '#' comment.
	return cat("trap \"exec ", sh, "\" INT\n", cmd, "\nexec ", sh)
}

attach_here :: proc(session, dir, cmd: string) -> ! {
	if dir != "" && !os.is_dir(dir) {
		fail(session, ": not a directory: ", dir)
	}
	os.write_string(os.stdout, cat("\x1b]0;", session, "\a"))
	if get_env("ZMX_SESSION") != "" {
		// Inside a session `zmx attach` only switches the client and drops the command.
		if _, exists := find_session(zmx_sessions()[:], session); !exists {
			create_detached(session, dir, cmd)
		}
		exec_cmd({"zmx", "attach", session})
	}
	if dir != "" {
		if e := os.set_working_directory(dir); e != nil {
			fail("cannot cd to ", dir, ": ", os.error_string(e))
		}
	}
	if cmd == "" {
		exec_cmd({"zmx", "attach", session})
	}
	// zmx ignores the command when the session already exists.
	exec_cmd({"zmx", "attach", session, shell_path(), "-c", pane_wrapper(cmd)})
}

// `zmx run -d` quotes each argument and types the line into a bash prompt;
// `exec` replaces bash, so zmx's task marker never runs.
create_detached :: proc(session, dir, cmd: string) {
	argv: [dynamic]string
	append(&argv, "zmx", "run", session, "-d", "exec", shell_path())
	if cmd == "" {
		append(&argv, "-l")
	} else {
		append(&argv, "-c", cat("clear\n", pane_wrapper(cmd)))
	}
	if r := run(argv[:], dir); !r.ok {
		fail("cannot create session ", session, ": ", strings.trim_space(r.err))
	}
}

kill_sessions :: proc(names: []string) {
	say("killing ", strings.join(names, " "))
	argv: [dynamic]string
	append(&argv, "zmx", "kill")
	append(&argv, ..names)
	if r := run(argv[:]); !r.ok {
		fail(strings.trim_space(r.err))
	}
}

project_sessions :: proc(project: string, sessions: []Session) -> []string {
	prefix := cat(project, ".")
	out: [dynamic]string
	for s in sessions {
		if strings.has_prefix(s.name, prefix) {
			append(&out, s.name)
		}
	}
	return out[:]
}
