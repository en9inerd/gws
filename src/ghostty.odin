package gws

import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

// Typed into the pane's own shell for the user's PATH; Ghostty's `command` skips the
// profile and leaves the pane open after exit.
write_surface_config :: proc(b: ^strings.Builder, session, dir: string) {
	exe, _ := os.get_executable_path(context.allocator)
	input := cat("exec ", shell_quote(exe), " attach ", shell_quote(session))
	strings.write_string(b, "\tset cfg to new surface configuration\n")
	strings.write_string(
		b,
		cat("\tset initial working directory of cfg to ", applescript_string(dir), "\n"),
	)
	strings.write_string(
		b,
		cat("\tset initial input of cfg to ", applescript_string(input), " & linefeed\n"),
	)
}

// Tabs in order of first appearance; in each tab, every pane after the first splits
// its `from` pane, or the previous one when `from` is not earlier in the tab. With
// here_tty, the first pane is that terminal and the caller attaches it.
build_open_script :: proc(p: Project, here_tty: string) -> string {
	tabs: [dynamic]string
	for pane in p.panes {
		if !slice.contains(tabs[:], pane.tab) {
			append(&tabs, pane.tab)
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "tell application \"Ghostty\"\n")
	for tab, t in tabs {
		opened: [dynamic]int
		for pane, i in p.panes {
			if pane.tab != tab {
				continue
			}
			v := cat("pane", itoa(i))
			if t == 0 && len(opened) == 0 && here_tty != "" {
				strings.write_string(
					&b,
					cat(
						"\tset ",
						v,
						" to first terminal whose tty is ",
						applescript_string(here_tty),
						"\n",
					),
				)
			} else {
				write_surface_config(&b, session_name(p.name, pane.name), pane.dir)
				switch {
				case len(opened) > 0:
					target := opened[len(opened) - 1]
					for j in opened {
						if p.panes[j].name == pane.from {
							target = j
						}
					}
					strings.write_string(
						&b,
						cat(
							"\tset ",
							v,
							" to split pane",
							itoa(target),
							" direction ",
							pane.split,
							" with configuration cfg\n",
						),
					)
				case t == 0:
					strings.write_string(&b, "\tif (count of windows) is 0 then\n")
					strings.write_string(
						&b,
						cat(
							"\t\tset ",
							v,
							" to focused terminal of selected tab of (new window with configuration cfg)\n",
						),
					)
					strings.write_string(&b, "\telse\n")
					strings.write_string(
						&b,
						cat(
							"\t\tset ",
							v,
							" to focused terminal of (new tab in front window with configuration cfg)\n",
						),
					)
					strings.write_string(&b, "\tend if\n")
				case:
					strings.write_string(
						&b,
						cat(
							"\tset ",
							v,
							" to focused terminal of (new tab in front window with configuration cfg)\n",
						),
					)
				}
			}
			append(&opened, i)
		}
		if len(opened) > 1 {
			strings.write_string(
				&b,
				cat("\tperform action \"equalize_splits\" on pane", itoa(opened[0]), "\n"),
			)
		}
	}
	strings.write_string(&b, "\tfocus pane0\nend tell\n")
	return strings.to_string(b)
}

// The tty of the Ghostty terminal gws runs in, or "". Inside zmx, or a pty nested
// in Ghostty (e.g. an editor's terminal), the tty is not Ghostty's.
ghostty_tty :: proc() -> string {
	if get_env("ZMX_SESSION") != "" || get_env("TERM_PROGRAM") != "ghostty" {
		return ""
	}
	tty := string(posix.ttyname(0))
	if tty == "" {
		return ""
	}
	query := cat(
		"tell application \"Ghostty\" to exists (first terminal whose tty is ",
		applescript_string(tty),
		")",
	)
	if r := run({"osascript", "-e", query}); strings.trim_space(r.out) != "true" {
		return ""
	}
	return tty
}

// A pane without split opens in a new tab.
build_add_script :: proc(session: string, pane: Pane) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "tell application \"Ghostty\"\n")
	write_surface_config(&b, session, pane.dir)
	if pane.split == "" {
		strings.write_string(&b, "\tnew tab in front window with configuration cfg\n")
	} else {
		strings.write_string(&b, "\tset p to focused terminal of selected tab of front window\n")
		strings.write_string(
			&b,
			cat("\tsplit p direction ", pane.split, " with configuration cfg\n"),
		)
	}
	strings.write_string(&b, "end tell\n")
	return strings.to_string(b)
}

require_macos :: proc(command: string) {
	when ODIN_OS != .Darwin {
		fail(
			command,
			" is not supported on ",
			ODIN_OS_STRING,
			": it drives Ghostty through AppleScript, which is macOS only",
		)
	}
}

// Returns an error message, "" on success.
run_applescript :: proc(script: string) -> string {
	if r := run({"osascript", "-e", script}); !r.ok {
		return cat("Ghostty AppleScript failed: ", strings.trim_space(r.err))
	}
	return ""
}
