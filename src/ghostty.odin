package gws

import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

NEW_TAB :: "focused terminal of (new tab in front window with configuration cfg)"
NEW_WINDOW :: "focused terminal of selected tab of (new window with configuration cfg)"

require_macos :: proc(command: string) {
	when ODIN_OS != .Darwin {
		fail(command, " is not supported on ", ODIN_OS_STRING)
	}
}

// Returns an error message, "" on success.
run_applescript :: proc(script: string) -> string {
	result := run_process({"osascript", "-e", script})
	if !result.started {
		return "osascript not found in PATH"
	}
	if !result.ok {
		return concat("Ghostty AppleScript failed: ", strings.trim_space(result.stderr))
	}
	return ""
}

// The tty of the Ghostty terminal gws runs in, or "". Only when the terminal's shell (the
// child of its session leader, login) started gws: that shell runs what gws types in once
// gws exits. gws must still be running then: at a prompt, shells take typed input as a
// paste and wait.
current_ghostty_tty :: proc() -> string {
	tty := string(posix.ttyname(0))
	if tty == "" || !in_ghostty_terminal(0) {
		return ""
	}
	shell, err := os.process_info_by_pid(int(posix.getppid()), {.PPid}, context.allocator)
	if err != nil || posix.pid_t(shell.ppid) != posix.getsid(0) {
		return ""
	}
	return strings.clone(tty)
}

// Whether the process (0: this one) runs in a Ghostty terminal: Ghostty started its session
// leader. Inside zmx, or a pty nested in Ghostty (e.g. an editor's terminal), something
// else did.
in_ghostty_terminal :: proc(pid: int) -> bool {
	leader := posix.getsid(posix.pid_t(pid))
	if leader == -1 {
		return false
	}
	info, err := os.process_info_by_pid(int(leader), {.PPid}, context.allocator)
	if err != nil {
		return false
	}
	parent, parent_err := os.process_info_by_pid(info.ppid, {.Executable_Path}, context.allocator)
	return parent_err == nil && os.base(parent.executable_path) == "ghostty"
}

// One Ghostty tab per tab name; in each tab, every pane after the first splits its
// `from` pane, or the closest one before it. open_terminals maps panes already open to
// their terminal's pid: their tab is not opened again, and the other panes of that tab
// split them. With here_tty, the first pane that needs a new tab is that terminal
// instead: its shell gets the attach typed in last.
open_layout_script :: proc(project: Project, here_tty: string, open_terminals: map[string]int = nil) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "tell application \"Ghostty\"\n")
	here_pane := -1
	focus_pane := -1
	has_window := len(open_terminals) > 0

	for tab in tab_names(project) {
		opened: [dynamic]int // indexes into project.panes
		to_open: [dynamic]int
		for pane, i in project.panes {
			if pane.tab == tab {
				append(&opened if pane.name in open_terminals else &to_open, i)
			}
		}
		if len(to_open) == 0 {
			continue
		}
		for i in opened {
			write_strings(&b, "\tset ", pane_variable(i), " to first terminal whose pid is ", int_to_string(open_terminals[project.panes[i].name]), "\n")
		}

		for i in to_open {
			pane := project.panes[i]
			terminal := pane_variable(i)
			if focus_pane == -1 {
				focus_pane = i
			}

			if len(opened) == 0 && here_tty != "" && here_pane == -1 {
				write_strings(&b, "\tset ", terminal, " to first terminal whose tty is ", applescript_string(here_tty), "\n")
				here_pane = i
				has_window = true
				append(&opened, i)
				continue
			}

			write_surface_config(&b, session_name(project.name, pane.name), pane.dir)
			switch {
			case len(opened) > 0:
				target, direction := split_target(project, opened[:], i)
				write_strings(&b, "\tset ", terminal, " to split ", pane_variable(target), " direction ", direction, " with configuration cfg\n")
			case !has_window:
				write_strings(
					&b,
					"\tif (count of windows) is 0 then\n",
					"\t\tset ", terminal, " to ", NEW_WINDOW, "\n",
					"\telse\n",
					"\t\tset ", terminal, " to ", NEW_TAB, "\n",
					"\tend if\n",
				)
				has_window = true
			case:
				write_strings(&b, "\tset ", terminal, " to ", NEW_TAB, "\n")
			}
			append(&opened, i)
		}

		if len(opened) > 1 {
			write_strings(&b, "\tperform action \"equalize_splits\" on ", pane_variable(opened[0]), "\n")
		}
	}

	write_strings(&b, "\tfocus ", pane_variable(focus_pane), "\n")
	if here_pane >= 0 {
		session := session_name(project.name, project.panes[here_pane].name)
		write_strings(&b, "\tinput text ", attach_input(session), " to ", pane_variable(here_pane), "\n")
	}
	strings.write_string(&b, "end tell\n")
	return strings.to_string(b)
}

// Splits the focused terminal with the pane, or opens it in a new tab when it has no split.
add_pane_script :: proc(session: string, pane: Pane) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "tell application \"Ghostty\"\n")
	write_surface_config(&b, session, pane.dir)
	if pane.split == "" {
		strings.write_string(&b, "\tnew tab in front window with configuration cfg\n")
	} else {
		write_strings(
			&b,
			"\tset p to focused terminal of selected tab of front window\n",
			"\tsplit p direction ", pane.split, " with configuration cfg\n",
		)
	}
	strings.write_string(&b, "end tell\n")
	return strings.to_string(b)
}

// Sets `cfg` to start in dir and attach the session, typed into the pane's shell for the
// user's PATH: Ghostty's `command` skips the profile and keeps the pane open after exit
// (ghostty#13167).
write_surface_config :: proc(b: ^strings.Builder, session, dir: string) {
	write_strings(
		b,
		"\tset cfg to new surface configuration\n",
		"\tset initial working directory of cfg to ",
		applescript_string(dir),
		"\n",
		"\tset initial input of cfg to ",
		attach_input(session),
		"\n",
	)
}

// AppleScript text that a shell runs to become the session's client. The leading space
// keeps it out of history with HIST_IGNORE_SPACE.
attach_input :: proc(session: string) -> string {
	gws_path, _ := os.get_executable_path(context.allocator)
	input := concat(" exec ", shell_quote(gws_path), " attach ", shell_quote(session))
	return concat(applescript_string(input), " & linefeed")
}

// Tab names in order of first appearance.
tab_names :: proc(project: Project) -> []string {
	names: [dynamic]string
	for pane in project.panes {
		if !slice.contains(names[:], pane.tab) {
			append(&names, pane.tab)
		}
	}
	return names[:]
}

// The open pane that pane i splits, and the direction: `from` when it is open in this
// tab, else the closest open pane before i. A pane before all open ones (a tab's first
// pane, reopened) goes on the far side of the next one, where it was.
split_target :: proc(project: Project, opened: []int, i: int) -> (target: int, direction: string) {
	pane := project.panes[i]
	target = -1
	for j in opened {
		if project.panes[j].name == pane.from {
			return j, pane.split
		}
		if j < i && j > target {
			target = j
		}
	}
	if target >= 0 {
		return target, pane.split
	}
	target = slice.min(opened)
	return target, opposite_split(project.panes[target].split)
}

opposite_split :: proc(direction: string) -> string {
	switch direction {
	case "right":
		return "left"
	case "left":
		return "right"
	case "down":
		return "up"
	case "up":
		return "down"
	}
	return direction
}

pane_variable :: proc(i: int) -> string {
	return concat("pane", int_to_string(i))
}
