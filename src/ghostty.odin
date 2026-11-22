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

// The tty of the Ghostty terminal gws runs in, or "". Inside zmx, or a pty nested
// in Ghostty (e.g. an editor's terminal), the tty is not Ghostty's.
current_ghostty_tty :: proc() -> string {
	if get_env("ZMX_SESSION") != "" || get_env("TERM_PROGRAM") != "ghostty" {
		return ""
	}
	tty := string(posix.ttyname(0))
	if tty == "" {
		return ""
	}
	query := concat(
		"tell application \"Ghostty\" to exists (first terminal whose tty is ",
		applescript_string(tty),
		")",
	)
	if result := run_process({"osascript", "-e", query}); strings.trim_space(result.stdout) != "true" {
		return ""
	}
	return strings.clone(tty)
}

// One Ghostty tab per tab name; in each tab, every pane after the first splits its
// `from` pane, or the previous one. With here_tty, the first pane is that terminal and
// the caller attaches it.
open_layout_script :: proc(project: Project, here_tty: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "tell application \"Ghostty\"\n")

	for tab, tab_index in tab_names(project) {
		opened: [dynamic]int // indexes into project.panes
		for pane, i in project.panes {
			if pane.tab != tab {
				continue
			}
			terminal := pane_variable(i)
			first_in_tab := len(opened) == 0

			if tab_index == 0 && first_in_tab && here_tty != "" {
				write_strings(&b, "\tset ", terminal, " to first terminal whose tty is ", applescript_string(here_tty), "\n")
				append(&opened, i)
				continue
			}

			write_surface_config(&b, session_name(project.name, pane.name), pane.dir)
			switch {
			case !first_in_tab:
				target := pane_variable(split_target(project, opened[:], pane.from))
				write_strings(&b, "\tset ", terminal, " to split ", target, " direction ", pane.split, " with configuration cfg\n")
			case tab_index == 0:
				write_strings(
					&b,
					"\tif (count of windows) is 0 then\n",
					"\t\tset ", terminal, " to ", NEW_WINDOW, "\n",
					"\telse\n",
					"\t\tset ", terminal, " to ", NEW_TAB, "\n",
					"\tend if\n",
				)
			case:
				write_strings(&b, "\tset ", terminal, " to ", NEW_TAB, "\n")
			}
			append(&opened, i)
		}

		if len(opened) > 1 {
			write_strings(&b, "\tperform action \"equalize_splits\" on ", pane_variable(opened[0]), "\n")
		}
	}

	strings.write_string(&b, "\tfocus pane0\nend tell\n")
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

// Sets `cfg` to start in dir and attach the session. The attach is typed into the pane's
// own shell for the user's PATH; Ghostty's `command` skips the profile and leaves the
// pane open after exit.
write_surface_config :: proc(b: ^strings.Builder, session, dir: string) {
	gws_path, _ := os.get_executable_path(context.allocator)
	input := concat("exec ", shell_quote(gws_path), " attach ", shell_quote(session))
	write_strings(
		b,
		"\tset cfg to new surface configuration\n",
		"\tset initial working directory of cfg to ",
		applescript_string(dir),
		"\n",
		"\tset initial input of cfg to ",
		applescript_string(input),
		" & linefeed\n",
	)
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

// The pane to split: `from` when it is already open in this tab, else the last one opened.
split_target :: proc(project: Project, opened: []int, from: string) -> int {
	for i in opened {
		if project.panes[i].name == from {
			return i
		}
	}
	return opened[len(opened) - 1]
}

// The AppleScript variable holding the terminal of project.panes[i].
pane_variable :: proc(i: int) -> string {
	return concat("pane", int_to_string(i))
}
