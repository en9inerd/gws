package gws

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_parse_zmx_list :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	output :=
		"  name=dev\tpid=1\tclients=2\tcreated=0\tcwd=file://host/Users/me/a%20b\n" +
		"→ name=cur.1\tpid=2\tclients=1\tcreated=0\tcwd=file://host/tmp\tcmd=/bin/zsh -c x\n" +
		"  name=gone\terr=ConnectionRefused\tstatus=unreachable\n" +
		"  name=old\tpid=3\tclients=0\tcreated=0\tended=5\n" +
		"\n" +
		"  pid=4\tclients=0\n" +
		"name=bare\n"
	sessions := parse_zmx_list(output)

	testing.expect_value(t, len(sessions), 3)
	testing.expect_value(t, sessions[0], Session{name = "dev", clients = 2, dir = "/Users/me/a b"})
	testing.expect_value(t, sessions[1], Session{name = "cur.1", clients = 1, dir = "/tmp"})
	testing.expect_value(t, sessions[2], Session{name = "bare"})

	testing.expect_value(t, len(parse_zmx_list("")), 0)
}

@(test)
test_cwd_url_to_path :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	testing.expect_value(t, cwd_url_to_path("file://host/Users/me/a%20b"), "/Users/me/a b")
	testing.expect_value(t, cwd_url_to_path("file:///tmp"), "/tmp")
	testing.expect_value(t, cwd_url_to_path("/plain/path"), "/plain/path")
	testing.expect_value(t, cwd_url_to_path("file://host/caf%C3%A9"), "/café")
	// Invalid escapes are kept as they are.
	testing.expect_value(t, cwd_url_to_path("file://host/bad%zz"), "/bad%zz")
}
@(test)
test_find_sessions :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	sessions := []Session {
		{name = "app.editor", clients = 1},
		{name = "apple.x"},
		{name = "app"},
		{name = "x.app.y"},
		{name = "app.server"},
	}
	session, found := find_session(sessions, "app.editor")
	testing.expect(t, found)
	testing.expect_value(t, session.clients, 1)
	_, found = find_session(sessions, "app.shell")
	testing.expect(t, !found)
	_, found = find_session(nil, "app")
	testing.expect(t, !found)

	testing.expect(t, is_session_live(sessions, "app"))
	testing.expect(t, !is_session_live(sessions, "ap"))

	names := project_sessions("app", sessions)
	testing.expectf(t, slice.equal(names, []string{"app.editor", "app.server"}), "got %v", names)
	testing.expect_value(t, len(project_sessions("none", sessions)), 0)
}

@(test)
test_pane_script :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	shell := shell_path()
	script := pane_script("npm start &")
	testing.expect_value(t, script, concat("trap \"exec ", shell_quote(shell), "\" INT\nnpm start &\nexec ", shell))

	// A trailing comment must not swallow the exec that keeps the session alive.
	script = pane_script("ls # list")
	testing.expect(t, strings.has_suffix(script, concat("ls # list\nexec ", shell)))
}
