package gws

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_open_layout_script :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := "dir = /w\n[editor]\ncmd = nvim .\n[server]\ncmd = npm start\ntab = run\n[shell]\nsplit = down\n"
	p, err := parse_project("app", text, "right")
	testing.expect_value(t, err, "")

	script := open_layout_script(p, "")
	testing.expect(t, strings.has_prefix(script, "tell application \"Ghostty\"\n"))
	testing.expect(t, strings.has_suffix(script, "\tfocus pane0\nend tell\n"))
	testing.expect_value(t, strings.count(script, "new tab in front window"), 2)
	testing.expect_value(t, strings.count(script, "new window with configuration cfg"), 1)
	testing.expect_value(t, strings.count(script, " to split "), 1)
	testing.expect(
		t,
		strings.contains(script, "set pane2 to split pane0 direction down with configuration cfg"),
	)
	testing.expect_value(t, strings.count(script, "equalize_splits"), 1)
	testing.expect(t, strings.contains(script, "perform action \"equalize_splits\" on pane0\n"))
	testing.expect_value(t, strings.count(script, "set initial input of cfg to"), 3)
	testing.expect_value(t, strings.count(script, "set initial working directory of cfg to \"/w\""), 3)
	testing.expect(t, strings.contains(script, ` attach 'app.server'" & linefeed`))
	// shell shares the main tab with editor, although it is listed after server.
	editor := strings.index(script, "app.editor")
	shell := strings.index(script, "app.shell")
	server := strings.index(script, "app.server")
	testing.expect(t, editor < shell && shell < server)

	here := open_layout_script(p, "/dev/ttys009")
	testing.expect(
		t,
		strings.contains(here, `set pane0 to first terminal whose tty is "/dev/ttys009"`),
	)
	testing.expect_value(t, strings.count(here, "new tab in front window"), 1)
	testing.expect_value(t, strings.count(here, "new window"), 0)
	testing.expect_value(t, strings.count(here, "set initial input of cfg to"), 2)
	testing.expect(t, strings.contains(here, "set pane2 to split pane0 direction down"))
	testing.expect(t, !strings.contains(here, "app.editor"))
}

@(test)
test_open_layout_script_single_pane :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	p, _ := parse_project("app", "dir = /w\n[shell]\ndir = /w/a \"b\"\n", "right")
	script := open_layout_script(p, "")
	testing.expect(t, !strings.contains(script, "equalize_splits"))
	testing.expect(t, !strings.contains(script, " to split "))
	testing.expect(t, strings.contains(script, "\tif (count of windows) is 0 then\n"))
	testing.expect(t, strings.contains(script, `set initial working directory of cfg to "/w/a \"b\""`))

	here := open_layout_script(p, "/dev/ttys001")
	testing.expect_value(
		t,
		here,
		"tell application \"Ghostty\"\n\tset pane0 to first terminal whose tty is \"/dev/ttys001\"\n\tfocus pane0\nend tell\n",
	)
}

@(test)
test_open_layout_script_from :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := "dir = /w\n[a]\n[b]\nsplit = down\n[c]\nfrom = a\n[d]\nfrom = gone\n[e]\ntab = t\n[f]\ntab = t\nfrom = a\n"
	p, err := parse_project("app", text, "right")
	testing.expect_value(t, err, "")

	script := open_layout_script(p, "")
	testing.expect(t, strings.contains(script, "set pane1 to split pane0 direction down"))
	testing.expect(t, strings.contains(script, "set pane2 to split pane0 direction right"))
	testing.expect(t, strings.contains(script, "set pane3 to split pane2 direction right"))
	// `from` in another tab falls back to the previous pane of this tab.
	testing.expect(t, strings.contains(script, "set pane5 to split pane4 direction right"))
	testing.expect_value(t, strings.count(script, "equalize_splits"), 2)
}

@(test)
test_layout_helpers :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	p, _ := parse_project("app", "dir = /w\n[a]\ntab = x\n[b]\n[c]\ntab = x\n[d]\ntab = y\n", "right")
	names := tab_names(p)
	testing.expectf(t, slice.equal(names, []string{"x", "main", "y"}), "got %v", names)

	opened := []int{0, 2}
	testing.expect_value(t, split_target(p, opened, "a"), 0)
	testing.expect_value(t, split_target(p, opened, "c"), 2)
	testing.expect_value(t, split_target(p, opened, "b"), 2)
	testing.expect_value(t, split_target(p, opened, ""), 2)

	testing.expect_value(t, pane_variable(0), "pane0")
	testing.expect_value(t, pane_variable(12), "pane12")
}

@(test)
test_add_pane_script :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	split := add_pane_script("app.2", Pane{split = "down", dir = "/w"})
	testing.expect(t, strings.contains(split, "set p to focused terminal of selected tab of front window\n"))
	testing.expect(t, strings.contains(split, "split p direction down with configuration cfg"))
	testing.expect(t, !strings.contains(split, "new tab"))
	testing.expect(t, strings.has_suffix(split, "end tell\n"))

	tab := add_pane_script("app.3", Pane{dir = "/w"})
	testing.expect(t, strings.contains(tab, "new tab in front window with configuration cfg"))
	testing.expect(t, !strings.contains(tab, "split"))
	testing.expect(t, strings.contains(tab, ` attach 'app.3'" & linefeed`))
}

@(test)
test_surface_config :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	b := strings.builder_make()
	write_surface_config(&b, "app.it's", "/w")
	exe, _ := os.get_executable_path(context.allocator)
	input := concat("exec ", shell_quote(exe), " attach 'app.it'\\''s'")
	testing.expect_value(
		t,
		strings.to_string(b),
		concat(
			"\tset cfg to new surface configuration\n",
			"\tset initial working directory of cfg to \"/w\"\n",
			"\tset initial input of cfg to ",
			applescript_string(input),
			" & linefeed\n",
		),
	)
}
