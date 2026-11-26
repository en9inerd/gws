package gws

import "base:runtime"
import "core:slice"
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
		"  name=ran\tpid=3\tclients=0\tcreated=0\tended=5\texit_code=127\tstatus=fail\n" +
		"\n" +
		"  pid=4\tclients=0\n" +
		"name=bare\n"
	sessions := parse_zmx_list(output)

	testing.expect_value(t, len(sessions), 4)
	testing.expect_value(t, sessions[0], Session{name = "dev", pid = 1, clients = 2, dir = "/Users/me/a b"})
	testing.expect_value(t, sessions[1], Session{name = "cur.1", pid = 2, clients = 1, dir = "/tmp"})
	testing.expect_value(t, sessions[2], Session{name = "ran", pid = 3})
	testing.expect_value(t, sessions[3], Session{name = "bare"})

	testing.expect_value(t, len(parse_zmx_list("")), 0)
}

@(test)
test_attach_command_session :: proc(t: ^testing.T) {
	testing.expect_value(t, attach_command_session({"zmx", "attach", "app.editor", "/bin/zsh", "-c", "nvim"}), "app.editor")
	testing.expect_value(t, attach_command_session({"/Users/me/.local/bin/zmx", "a", "app.shell"}), "app.shell")
	testing.expect_value(t, attach_command_session({"zmx", "attach", "--labels", "x=y", "app.other"}), "")
	testing.expect_value(t, attach_command_session({"zmx", "kill", "app.server"}), "")
	testing.expect_value(t, attach_command_session({"nvim", "zmx", "attach", "fake"}), "")
	testing.expect_value(t, attach_command_session({"zmx", "attach"}), "")
	testing.expect_value(t, attach_command_session({}), "")
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
test_attach_command :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	command := attach_command("app.server", "npm start &")
	want := []string{"zmx", "attach", "app.server", "/bin/sh", "-c", PANE_SCRIPT, shell_path(), "npm start &"}
	testing.expectf(t, slice.equal(command, want), "got %v", command)
	command = attach_command("app.shell", "")
	testing.expectf(t, slice.equal(command, []string{"zmx", "attach", "app.shell"}), "got %v", command)
}
