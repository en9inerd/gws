package gws

import "core:os"
import "core:strings"
import "core:sys/posix"

FZF_NO_MATCH :: 1
FZF_CANCELLED :: 130

fzf :: proc(lines: []string, options: ..string) -> (output: []string, code: int) {
	in_r, in_w, e1 := os.pipe()
	out_r, out_w, e2 := os.pipe()
	if e1 != nil || e2 != nil {
		fail("cannot create pipe")
	}
	argv: [dynamic]string
	append(&argv, "fzf")
	append(&argv, ..options)
	process, err := os.process_start(
		{command = argv[:], stdin = in_r, stdout = out_w, stderr = os.stderr},
	)
	os.close(in_r)
	os.close(out_w)
	if err != nil {
		fail("fzf not found in PATH (install fzf)")
	}

	// fzf may exit before reading everything (Esc); writes must not kill gws.
	posix.sigignore(.SIGPIPE)
	os.write_string(in_w, strings.join(lines, "\n"))
	os.close(in_w)

	out, _ := os.read_entire_file(out_r, context.allocator)
	os.close(out_r)
	state, _ := os.process_wait(process)
	output, _ = strings.split_lines(strings.trim_right(string(out), "\n"))
	return output, state.exit_code
}

HERE_PREFIX :: "[here] "
ZMX_PREFIX :: "[zmx] "
PROJECT_PREFIX :: "[project] "
PANE_PREFIX :: "[pane] "

pick_candidates :: proc(g: Global, sessions: []Session) -> []string {
	lines: [dynamic]string
	if cwd, e := os.get_working_directory(context.allocator); e == nil {
		append(&lines, cat(HERE_PREFIX, cwd))
	}
	for s in sessions {
		append(
			&lines,
			cat(
				ZMX_PREFIX,
				pad(s.name, 24),
				"clients:",
				pad(itoa(s.clients), 2),
				collapse_home(s.dir),
			),
		)
	}
	names := project_names()
	for name in names {
		append(&lines, cat(PROJECT_PREFIX, name))
	}
	for name in names {
		p, err := try_load_project(name, g)
		if err != "" {
			continue
		}
		for pane in p.panes {
			sn := session_name(p.name, pane.name)
			if _, live := find_session(sessions, sn); !live {
				append(&lines, cat(PANE_PREFIX, sn))
			}
		}
	}
	for sp in g.search {
		walk_dirs(sp.path, sp.depth if sp.depth > 0 else g.depth, &lines)
	}
	return lines[:]
}

cmd_pick :: proc(kill: bool) {
	g := load_global()
	sessions := zmx_sessions()

	if kill {
		names: [dynamic]string
		for s in sessions {
			append(&names, s.name)
		}
		if len(names) == 0 {
			say("no live sessions")
			return
		}
		out, _ := fzf(names[:], "--prompt=kill> ", "--height=40%", "--border=rounded", "--reverse")
		if out[0] != "" {
			kill_sessions(out[:1])
		}
		return
	}

	out, code := fzf(
		pick_candidates(g, sessions[:]),
		"--print-query",
		"--prompt=session> ",
		"--height=80%",
		"--reverse",
		"--border=rounded",
	)
	if code == FZF_CANCELLED {
		return
	}
	query := out[0]
	sel := out[1] if len(out) > 1 else ""
	switch {
	case strings.has_prefix(sel, ZMX_PREFIX):
		fields := strings.fields(sel[len(ZMX_PREFIX):])
		attach_here(fields[0], "", "")
	case strings.has_prefix(sel, PROJECT_PREFIX):
		open_project(sel[len(PROJECT_PREFIX):], false)
	case strings.has_prefix(sel, PANE_PREFIX):
		attach_target(sel[len(PANE_PREFIX):], g)
	case strings.has_prefix(sel, HERE_PREFIX):
		attach_dir(sel[len(HERE_PREFIX):])
	case sel != "":
		attach_dir(sel)
	case code == FZF_NO_MATCH && query != "":
		name := sanitize_name(query)
		if !valid_name(name) {
			fail("invalid session name ", quote(query))
		}
		attach_here(name, "", "")
	}
}

// The only project, else the one whose dir is the current directory, else fzf.
pick_project :: proc() -> string {
	names := project_names()
	switch len(names) {
	case 0:
		fail("no projects (create one: gws new <name>)")
	case 1:
		return names[0]
	}
	if cwd, e := os.get_working_directory(context.allocator); e == nil {
		g := load_global()
		for name in names {
			if p, err := try_load_project(name, g);
			   err == "" && strings.trim_right(p.dir, "/") == cwd {
				return name
			}
		}
	}
	out, _ := fzf(names, "--prompt=project> ", "--height=40%", "--border=rounded", "--reverse")
	return out[0]
}

attach_dir :: proc(dir: string) -> ! {
	name := sanitize_name(os.base(dir))
	if !valid_name(name) {
		fail("cannot derive a session name from ", dir)
	}
	attach_here(name, dir, "")
}
