package gws

import "core:os"
import "core:strings"
import "core:sys/posix"

FZF_NO_MATCH :: 1
FZF_CANCELLED :: 130

// Prefixes that tell picker lines apart; plain lines are directories.
HERE_PREFIX :: "[here] "
SESSION_PREFIX :: "[zmx] "
PROJECT_PREFIX :: "[project] "
PANE_PREFIX :: "[pane] "

// Output lines of fzf (always at least one, possibly "") and its exit code.
fzf :: proc(lines: []string, options: ..string) -> (output: []string, exit_code: int) {
	stdin_r, stdin_w, pipe_err1 := os.pipe()
	stdout_r, stdout_w, pipe_err2 := os.pipe()
	if pipe_err1 != nil || pipe_err2 != nil {
		fail("cannot create pipe")
	}
	command: [dynamic]string
	append(&command, "fzf")
	append(&command, ..options)
	process, start_err := os.process_start(
		{command = command[:], stdin = stdin_r, stdout = stdout_w, stderr = os.stderr},
	)
	os.close(stdin_r)
	os.close(stdout_w)
	if start_err != nil {
		fail("fzf not found in PATH (install fzf)")
	}

	// fzf may exit before reading everything (Esc); writes must not kill gws. Restored
	// after: an ignored SIGPIPE survives exec into zmx and every shell it starts.
	previous_handler := posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	os.write_string(stdin_w, strings.join(lines, "\n"))
	os.close(stdin_w)
	posix.signal(.SIGPIPE, previous_handler)

	data, _ := os.read_entire_file(stdout_r, context.allocator)
	os.close(stdout_r)
	state, _ := os.process_wait(process)
	output = strings.split_lines(strings.trim_right(string(data), "\n"))
	return output, state.exit_code
}

// The current directory, live sessions except this one, projects, project panes that
// are not running, then directories under the search paths.
picker_lines :: proc(config: Config, sessions: []Session) -> []string {
	lines: [dynamic]string
	if cwd, err := os.get_working_directory(context.allocator); err == nil {
		append(&lines, concat(HERE_PREFIX, cwd))
	}
	current_session := get_env("ZMX_SESSION")
	for session in sessions {
		if session.name == current_session {
			continue
		}
		pid := pad_right(int_to_string(session.pid), 7)
		clients := pad_right(int_to_string(session.clients), 2)
		append(&lines, concat(SESSION_PREFIX, pad_right(session.name, 24), "pid:", pid, "clients:", clients, collapse_home(session.dir)))
	}
	names := project_names()
	for name in names {
		append(&lines, concat(PROJECT_PREFIX, name))
	}
	for name in names {
		project, err := try_load_project(name, config)
		if err != "" {
			continue
		}
		for pane in project.panes {
			session := session_name(project.name, pane.name)
			if !is_session_live(sessions, session) {
				append(&lines, concat(PANE_PREFIX, session))
			}
		}
	}
	for search in config.search_paths {
		depth := search.depth if search.depth > 0 else config.search_depth
		walk_dirs(search.path, depth, &lines)
	}
	return lines[:]
}

cmd_pick :: proc(kill: bool) {
	if kill {
		pick_and_kill()
		return
	}

	config := load_config()
	output, exit_code := fzf(
		picker_lines(config, live_sessions()),
		"--print-query",
		"--prompt=session> ",
		"--height=80%",
		"--reverse",
		"--border=rounded",
	)
	if exit_code == FZF_CANCELLED {
		return
	}
	query := output[0]
	selection := output[1] if len(output) > 1 else ""
	switch {
	case strings.has_prefix(selection, SESSION_PREFIX):
		fields := strings.fields(selection[len(SESSION_PREFIX):])
		attach_session(fields[0], "", "")
	case strings.has_prefix(selection, PROJECT_PREFIX):
		open_project(selection[len(PROJECT_PREFIX):], false)
	case strings.has_prefix(selection, PANE_PREFIX):
		attach_target(selection[len(PANE_PREFIX):], config)
	case strings.has_prefix(selection, HERE_PREFIX):
		attach_dir(selection[len(HERE_PREFIX):])
	case selection != "":
		attach_dir(selection)
	case exit_code == FZF_NO_MATCH && query != "":
		// A new session named after what was typed.
		name := sanitize_name(query)
		if !is_valid_name(name) {
			fail("invalid session name ", quoted(query))
		}
		attach_session(name, "", "")
	}
}

pick_and_kill :: proc() {
	names: [dynamic]string
	for session in live_sessions() {
		append(&names, session.name)
	}
	if len(names) == 0 {
		print_line("no live sessions")
		return
	}
	output, _ := fzf(names[:], "--prompt=kill> ", "--height=40%", "--border=rounded", "--reverse")
	if output[0] != "" {
		kill_sessions(output[:1])
	}
}

// The project whose dir is the current directory, else the only one, else fzf.
// "" when the picker is cancelled.
pick_project :: proc() -> string {
	names := project_names()
	if len(names) == 0 {
		fail("no projects (create one: gws new <name>)")
	}
	if cwd, err := os.get_working_directory(context.allocator); err == nil {
		config := load_config()
		for name in names {
			project, load_err := try_load_project(name, config)
			if load_err == "" && strings.trim_right(project.dir, "/") == cwd {
				return name
			}
		}
	}
	if len(names) == 1 {
		return names[0]
	}
	output, _ := fzf(names, "--prompt=project> ", "--height=40%", "--border=rounded", "--reverse")
	return output[0]
}
