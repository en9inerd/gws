package gws

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_names :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	testing.expect_value(t, is_valid_name("a-b_9"), true)
	testing.expect_value(t, is_valid_name("A"), true)
	testing.expect_value(t, is_valid_name("a.b"), false)
	testing.expect_value(t, is_valid_name("a b"), false)
	testing.expect_value(t, is_valid_name("é"), false)
	testing.expect_value(t, is_valid_name(""), false)

	testing.expect_value(t, sanitize_name("my app.v2!!x"), "my_app_v2_x")
	testing.expect_value(t, sanitize_name("ok-name_1"), "ok-name_1")
	testing.expect_value(t, sanitize_name("..."), "_")
	testing.expect_value(t, sanitize_name("a__b"), "a_b")
	testing.expect_value(t, sanitize_name(""), "")

	for split in ([]string{"right", "left", "down", "up"}) {
		testing.expect(t, is_valid_split(split))
	}
	testing.expect(t, !is_valid_split("Right"))
	testing.expect(t, !is_valid_split(""))

	testing.expect_value(t, session_name("app", "editor"), "app.editor")
	project_name, pane_name, ok := split_session_name("app.editor")
	testing.expect_value(t, project_name, "app")
	testing.expect_value(t, pane_name, "editor")
	testing.expect_value(t, ok, true)
	// Only the first '.' separates: pane names cannot contain one, but sessions can.
	project_name, pane_name, ok = split_session_name("app.a.b")
	testing.expect_value(t, project_name, "app")
	testing.expect_value(t, pane_name, "a.b")
	for s in ([]string{"plain", ".pane", "project.", ""}) {
		project_name, _, ok = split_session_name(s)
		testing.expectf(t, !ok, "%q has no pane", s)
		testing.expect_value(t, project_name, s)
	}
}

@(test)
test_parse_ini :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := "; comment\n# comment\n  key = some value  \n\n[ sec ]\nempty =\nq = \"a \\\"b\\\"\"\nbad = \"unterminated\neq = a=b\r\n"
	entries, err := parse_ini(text)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(entries), 6)
	testing.expect_value(t, entries[0], Ini_Entry{line = 3, key = "key", value = "some value"})
	testing.expect_value(t, entries[1], Ini_Entry{line = 5, is_section = true, key = "sec"})
	testing.expect_value(t, entries[2], Ini_Entry{line = 6, key = "empty", value = ""})
	testing.expect_value(t, entries[3].value, `a "b"`)
	testing.expect_value(t, entries[4].value, `"unterminated`)
	testing.expect_value(t, entries[5], Ini_Entry{line = 9, key = "eq", value = "a=b"})

	_, err = parse_ini("a = 1\n[open\n")
	testing.expect_value(t, err, "line 2: missing ']'")
	_, err = parse_ini("\n\njust words\n")
	testing.expect_value(t, err, "line 3: expected 'key = value'")

	entries, err = parse_ini("")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(entries), 0)
}

@(test)
test_parse_project :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := `dir = /work/app
; comment
[editor]
cmd = nvim .

[shell]
split = down
from = editor

[server]
cmd = "npm start"
tab = run
dir = api

[logs]
dir = /var/log
`
	p, err := parse_project("app", text, "right")

	testing.expect_value(t, err, "")
	testing.expect_value(t, p.name, "app")
	testing.expect_value(t, p.dir, "/work/app")
	testing.expect_value(t, p.path, "")
	testing.expect_value(t, len(p.panes), 4)
	testing.expect_value(t, p.panes[0], Pane{name = "editor", cmd = "nvim .", tab = "main", split = "right", dir = "/work/app"})
	testing.expect_value(t, p.panes[1], Pane{name = "shell", tab = "main", split = "down", from = "editor", dir = "/work/app"})
	testing.expect_value(t, p.panes[2], Pane{name = "server", cmd = "npm start", tab = "run", split = "right", dir = "/work/app/api"})
	testing.expect_value(t, p.panes[3].dir, "/var/log")

	// The default split comes from the caller (config.ini).
	p, err = parse_project("app", "dir = /w\n[a]\n", "up")
	testing.expect_value(t, p.panes[0].split, "up")

	// A project with no panes parses; `open` rejects it later.
	p, err = parse_project("app", "dir = /w\n", "right")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(p.panes), 0)
}

@(test)
test_parse_project_home :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	home := get_env("HOME")
	if home == "" {
		return
	}
	p, err := parse_project("app", "dir = ~/app\n[a]\n[b]\ndir = ~/other\n", "right")
	testing.expect_value(t, err, "")
	testing.expect_value(t, p.dir, concat(home, "/app"))
	testing.expect_value(t, p.panes[0].dir, concat(home, "/app"))
	testing.expect_value(t, p.panes[1].dir, concat(home, "/other"))
}

@(test)
test_parse_project_errors :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	Case :: struct {
		text: string,
		err:  string,
	}
	cases := []Case {
		{"[a]\n", "missing 'dir = ...'"},
		{"", "missing 'dir = ...'"},
		{"dir = rel/x\n[a]\n", "dir must be absolute or start with ~/"},
		{"dir = /x\n[a.b]\n", `line 2: invalid pane name "a.b" (use A-Z a-z 0-9 _ -)`},
		{"dir = /x\n[]\n", `line 2: invalid pane name "" (use A-Z a-z 0-9 _ -)`},
		{"dir = /x\n[a]\n[a]\n", `line 3: duplicate pane "a"`},
		{"dir = /x\n[a]\nsplit = sideways\n", "line 3: split must be right, left, down or up"},
		{"dir = /x\n[a]\nfrom = a.b\n", `line 3: invalid pane name "a.b"`},
		{"dir = /x\n[a]\ntab = my tab\n", `line 3: invalid tab name "my tab"`},
		{"dir = /x\n[a]\nfoo = 1\n", `line 3: unknown pane key "foo"`},
		{"dir = /x\ncmd = ls\n", `line 2: unknown project key "cmd"`},
		{"dir = /x\nnot a pair\n", "line 2: expected 'key = value'"},
		{"dir = /x\n[a\n", "line 2: missing ']'"},
	}
	for c in cases {
		_, err := parse_project("p", c.text, "right")
		testing.expectf(t, err == c.err, "%q: got %q, want %q", c.text, err, c.err)
	}
}

@(test)
test_parse_config :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	config := default_config()
	testing.expect_value(t, config.search_depth, 1)
	testing.expect_value(t, config.default_split, "right")
	testing.expect_value(t, len(config.search_paths), 0)

	err := parse_config("search = /a\nsearch = /b:3\nsearch = /c:x\nsearch = /d:0\ndepth = 2\nsplit = down\n", &config)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(config.search_paths), 4)
	testing.expect_value(t, config.search_paths[0], Search_Path{path = "/a"})
	testing.expect_value(t, config.search_paths[1], Search_Path{path = "/b", depth = 3})
	// Not a positive depth: the colon is part of the path.
	testing.expect_value(t, config.search_paths[2], Search_Path{path = "/c:x"})
	testing.expect_value(t, config.search_paths[3], Search_Path{path = "/d:0"})
	testing.expect_value(t, config.search_depth, 2)
	testing.expect_value(t, config.default_split, "down")

	if home := get_env("HOME"); home != "" {
		config = default_config()
		err = parse_config("search = ~/Work:2\n", &config)
		testing.expect_value(t, err, "")
		testing.expect_value(t, config.search_paths[0], Search_Path{path = concat(home, "/Work"), depth = 2})
	}

	Case :: struct {
		text: string,
		err:  string,
	}
	cases := []Case {
		{"[x]\n", "line 1: sections are not used in config.ini"},
		{"search = rel\n", "line 1: search must be absolute or start with ~/"},
		{"depth = 0\n", "line 1: depth must be a positive number"},
		{"depth = two\n", "line 1: depth must be a positive number"},
		{"split = sideways\n", "line 1: split must be right, left, down or up"},
		{"\ncolor = red\n", `line 2: unknown key "color"`},
		{"oops\n", "line 1: expected 'key = value'"},
	}
	for c in cases {
		config = default_config()
		err = parse_config(c.text, &config)
		testing.expectf(t, err == c.err, "%q: got %q, want %q", c.text, err, c.err)
	}
}

@(test)
test_new_project_round_trip :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := new_project_text("/work/p")
	testing.expect_value(t, text, "dir = /work/p\n\n[shell]\n")
	p, err := parse_project("p", text, "right")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(p.panes), 1)
	testing.expect_value(t, p.panes[0].name, "shell")
	testing.expect_value(t, p.panes[0].dir, "/work/p")
}

@(test)
test_find_pane :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	p, _ := parse_project("app", "dir = /w\n[a]\n[b]\n", "right")
	pane, found := find_pane(p, "b")
	testing.expect(t, found)
	testing.expect_value(t, pane.name, "b")
	// The result points into the project.
	pane.cmd = "ls"
	testing.expect_value(t, p.panes[1].cmd, "ls")

	_, found = find_pane(p, "c")
	testing.expect(t, !found)
}

@(test)
test_first_pane_of_next_tab :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	p, err := parse_project("app", "dir = /w\n[a]\n[b]\ntab = run\n[c]\n[d]\ntab = x\n", "right")
	testing.expect_value(t, err, "")
	testing.expect_value(t, first_pane_of_next_tab(p, "main"), "b")
	testing.expect_value(t, first_pane_of_next_tab(p, "run"), "d")
	testing.expect_value(t, first_pane_of_next_tab(p, "x"), "")
	testing.expect_value(t, first_pane_of_next_tab(p, "gone"), "")
}

@(test)
test_next_pane_name :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	p, err := parse_project("app", "dir = /w\n[a]\n[2]\n[b]\ntab = 3\n", "right")
	testing.expect_value(t, err, "")

	// 2 is a pane, 3 a tab, 4 a live session left over from an earlier pane.
	sessions := []Session{{name = "app.4"}, {name = "other.5"}}
	testing.expect_value(t, next_pane_name(p, sessions), "5")
	testing.expect_value(t, next_pane_name(p, nil), "4")

	empty, _ := parse_project("app", "dir = /w\n", "right")
	testing.expect_value(t, next_pane_name(empty, nil), "2")

	testing.expect(t, !is_pane_name_free(p, sessions, "a"))
	testing.expect(t, !is_pane_name_free(p, sessions, "3"))
	testing.expect(t, !is_pane_name_free(p, sessions, "4"))
	testing.expect(t, is_pane_name_free(p, sessions, "logs"))
	testing.expect(t, is_pane_name_free(p, sessions, "5"))
}

@(test)
test_pane_section :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	p := Project {
		dir = "/w",
	}
	testing.expect_value(
		t,
		pane_section(p, Pane{name = "2", tab = "main", split = "down", from = "a", dir = "/w"}),
		"[2]\ntab = main\nsplit = down\nfrom = a\n",
	)
	testing.expect_value(
		t,
		pane_section(p, Pane{name = "3", tab = "3", dir = "/w/api"}),
		"[3]\ntab = 3\ndir = /w/api\n",
	)
	if home := get_env("HOME"); home != "" {
		testing.expect_value(
			t,
			pane_section(p, Pane{name = "4", tab = "4", dir = concat(home, "/x")}),
			"[4]\ntab = 4\ndir = ~/x\n",
		)
	}

	// What gws writes, it reads back the same.
	added := Pane {
		name  = "2",
		tab   = "main",
		split = "up",
		from  = "a",
		dir   = "/w/sub",
	}
	text := insert_section("dir = /w\n\n[a]\n", pane_section(p, added), "")
	back, err := parse_project("app", text, "right")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(back.panes), 2)
	testing.expect_value(t, back.panes[1], added)
}

@(test)
test_insert_section :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := "dir = /w\n\n[a]\n\n[b]\ntab = run\n"
	testing.expect_value(
		t,
		insert_section(text, "[3]\ntab = 3\n", "b"),
		"dir = /w\n\n[a]\n\n[3]\ntab = 3\n\n[b]\ntab = run\n",
	)
	testing.expect_value(
		t,
		insert_section(text, "[3]\ntab = 3\n", ""),
		"dir = /w\n\n[a]\n\n[b]\ntab = run\n\n[3]\ntab = 3\n",
	)
	testing.expect_value(
		t,
		insert_section(text, "[3]\n", "gone"),
		"dir = /w\n\n[a]\n\n[b]\ntab = run\n\n[3]\n",
	)
	testing.expect_value(t, insert_section("dir = /w", "[3]\n", ""), "dir = /w\n\n[3]\n")
	testing.expect_value(t, insert_section("", "[3]\n", ""), "\n[3]\n")
	// Headers are matched by name, whatever their spacing.
	testing.expect_value(t, insert_section("[ b ]\n", "[3]\n", "b"), "[3]\n\n[ b ]\n")
}

@(test)
test_remove_section :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	text := "dir = /w\n\n[a]\n\n[ b ]\ntab = x\nsplit = down\n\n[c]\ncmd = ls\n"
	testing.expect_value(t, remove_section(text, "b"), "dir = /w\n\n[a]\n\n[c]\ncmd = ls\n")
	testing.expect_value(
		t,
		remove_section(text, "c"),
		"dir = /w\n\n[a]\n\n[ b ]\ntab = x\nsplit = down\n\n",
	)
	testing.expect_value(t, remove_section(text, "a"), "dir = /w\n\n[ b ]\ntab = x\nsplit = down\n\n[c]\ncmd = ls\n")
	testing.expect_value(t, remove_section(text, "gone"), text)
	testing.expect_value(t, remove_section("", "a"), "")
}

@(test)
test_section_header :: proc(t: ^testing.T) {
	name, ok := section_header("  [ editor ]  \n")
	testing.expect(t, ok)
	testing.expect_value(t, name, "editor")
	name, ok = section_header("[a]")
	testing.expect_value(t, name, "a")
	_, ok = section_header("dir = [x]\n")
	testing.expect(t, !ok)
	_, ok = section_header("\n")
	testing.expect(t, !ok)
}

// Only this test sets XDG_CONFIG_HOME; the Makefile runs tests on one thread.
@(test)
test_project_files :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	root := make_temp_dir(t)
	defer remove_temp_dir(root)
	saved := set_test_env("XDG_CONFIG_HOME", root)
	defer restore_env(saved)

	testing.expect_value(t, config_dir(), concat(root, "/gws"))
	testing.expect_value(t, projects_dir(), concat(root, "/gws/projects"))
	testing.expect_value(t, project_path("app"), concat(root, "/gws/projects/app.ini"))

	// No projects and no config.ini yet: the defaults apply.
	testing.expect_value(t, len(project_names()), 0)
	testing.expect(t, !project_exists("app"))
	config := load_config()
	testing.expect_value(t, config.search_depth, 1)
	testing.expect_value(t, config.default_split, "right")
	testing.expect_value(t, len(config.search_paths), 1)
	testing.expect_value(t, config.search_paths[0].path, expand_home("~/Development"))

	projects := projects_dir()
	make_test_dir(t, projects)
	make_test_dir(t, concat(projects, "/folder.ini"))
	make_test_file(t, concat(projects, "/notes.txt"), "not a project")
	make_test_file(t, concat(projects, "/b.ini"), "dir = /b\n[shell]\n")
	make_test_file(t, concat(projects, "/a.ini"), "dir = /a\n[editor]\n[shell]\nsplit = down\n[server]\n")
	make_test_file(t, concat(projects, "/broken.ini"), "dir = rel\n[x]\n")

	names := project_names()
	testing.expectf(t, slice.equal(names, []string{"a", "b", "broken"}), "names: %v", names)
	testing.expect(t, project_exists("a"))
	testing.expect(t, !project_exists("folder"))
	testing.expect(t, !project_exists("notes"))
	testing.expect(t, !project_exists("a.ini"))
	testing.expect(t, !project_exists("../gws/projects/a"))

	p, err := try_load_project("a", config)
	testing.expect_value(t, err, "")
	testing.expect_value(t, p.path, project_path("a"))
	testing.expect_value(t, len(p.panes), 3)
	testing.expect_value(t, p.panes[0].split, "right")
	testing.expect_value(t, load_project("a", config).dir, "/a")

	_, err = try_load_project("broken", config)
	testing.expect_value(t, err, concat(project_path("broken"), ": dir must be absolute or start with ~/"))
	_, err = try_load_project("missing", config)
	testing.expect_value(t, err, `project "missing" not found (create it: gws new missing)`)
	_, err = try_load_project("a/b", config)
	testing.expect_value(t, err, `invalid project name "a/b"`)

	// config.ini sets the default split for panes without one.
	make_test_file(t, concat(config_dir(), "/config.ini"), "search = /s:2\nsplit = up\n")
	config = load_config()
	testing.expect_value(t, len(config.search_paths), 1)
	testing.expect_value(t, config.search_paths[0], Search_Path{path = "/s", depth = 2})
	p = load_project("a", config)
	testing.expect_value(t, p.panes[0].split, "up")
	testing.expect_value(t, p.panes[1].split, "down")

	// The picker lists the current directory, sessions, projects, stopped panes, then dirs.
	search := concat(root, "/search")
	make_test_dir(t, concat(search, "/one"))
	config.search_paths[0] = {path = search}
	sessions := []Session{{name = "a.editor", pid = 42, clients = 1, dir = "/a"}, {name = "misc"}}
	lines := picker_lines(config, sessions)
	cwd, _ := os.get_working_directory(context.allocator)
	expected := []string {
		concat("[here] ", cwd),
		concat("[zmx] a.editor", strings.repeat(" ", 17), "pid:42      clients:1  /a"),
		concat("[zmx] misc", strings.repeat(" ", 21), "pid:0       clients:0  "),
		"[project] a",
		"[project] b",
		"[project] broken",
		"[pane] a.shell",
		"[pane] a.server",
		"[pane] b.shell",
		concat(search, "/one"),
	}
	testing.expectf(t, slice.equal(lines, expected), "picker lines:\n%s", strings.join(lines, "\n"))
}
