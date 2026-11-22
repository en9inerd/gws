package gws

import "core:strings"
import "core:testing"

@(test)
test_parse_project :: proc(t: ^testing.T) {
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
`
	p, err := parse_project("app", text, "right")
	defer delete_project(&p)

	testing.expect_value(t, err, "")
	testing.expect_value(t, p.dir, "/work/app")
	testing.expect_value(t, len(p.panes), 3)
	testing.expect_value(t, p.panes[0].cmd, "nvim .")
	testing.expect_value(t, p.panes[0].tab, "main")
	testing.expect_value(t, p.panes[0].split, "right")
	testing.expect_value(t, p.panes[0].dir, "/work/app")
	testing.expect_value(t, p.panes[1].cmd, "")
	testing.expect_value(t, p.panes[1].split, "down")
	testing.expect_value(t, p.panes[1].from, "editor")
	testing.expect_value(t, p.panes[0].from, "")
	testing.expect_value(t, p.panes[2].cmd, "npm start")
	testing.expect_value(t, p.panes[2].tab, "run")
	testing.expect_value(t, p.panes[2].dir, "/work/app/api")
}

@(test)
test_parse_project_errors :: proc(t: ^testing.T) {
	cases := []string {
		"[a]\n", // missing dir
		"dir = rel/x\n[a]\n",
		"dir = /x\n[a.b]\n", // invalid pane name
		"dir = /x\n[a]\n[a]\n", // duplicate
		"dir = /x\n[a]\nsplit = sideways\n",
		"dir = /x\n[a]\nfrom = a.b\n",
		"dir = /x\n[a]\nfoo = 1\n",
		"dir = /x\nnot a pair\n",
	}

	for c in cases {
		p, err := parse_project("p", c, "right")
		defer delete_project(&p)
		defer delete(err)

		testing.expectf(t, err != "", "expected error for %q", c)
	}
}

@(test)
test_new_project_round_trip :: proc(t: ^testing.T) {
	text := new_project_text("/work/p")
	defer delete(text)

	p, err := parse_project("p", text, "right")
	defer delete_project(&p)

	testing.expect_value(t, err, "")
	testing.expect_value(t, len(p.panes), 1)
	testing.expect_value(t, p.panes[0].name, "shell")
}

@(test)
test_parse_global :: proc(t: ^testing.T) {
	g := Global {
		depth = 1,
		split = "right",
	}
	defer delete_global(&g)

	err := parse_global("search = /a\nsearch = /b:3\ndepth = 2\nsplit = down\n", &g)
	defer delete(err)

	testing.expect_value(t, err, "")
	testing.expect_value(t, len(g.search), 2)
	testing.expect_value(t, g.search[0].path, "/a")
	testing.expect_value(t, g.search[0].depth, 0)
	testing.expect_value(t, g.search[1].path, "/b")
	testing.expect_value(t, g.search[1].depth, 3)
	testing.expect_value(t, g.depth, 2)
	testing.expect_value(t, g.split, "down")
}

@(test)
test_parse_zmx_list :: proc(t: ^testing.T) {
	out :=
		"  name=dev\tpid=1\tclients=2\tcreated=0\tcwd=file://host/Users/me/a%20b\n" +
		"→ name=cur.1\tpid=2\tclients=1\tcreated=0\tcwd=file://host/tmp\tcmd=/bin/zsh -c x\n" +
		"  name=gone\terr=ConnectionRefused\tstatus=unreachable\n" +
		"  name=old\tpid=3\tclients=0\tcreated=0\tended=5\n"
	s := parse_zmx_list(out)
	defer {
		for &session in s {
			delete(session.dir)
		}
		delete(s)
	}

	testing.expect_value(t, len(s), 2)
	testing.expect_value(t, s[0].name, "dev")
	testing.expect_value(t, s[0].clients, 2)
	testing.expect_value(t, s[0].dir, "/Users/me/a b")
	testing.expect_value(t, s[1].name, "cur.1")
	testing.expect_value(t, s[1].dir, "/tmp")
}

@(test)
test_names :: proc(t: ^testing.T) {
	name := sanitize_name("my app.v2!!x")
	defer delete(name)

	testing.expect_value(t, name, "my_app_v2_x")
	testing.expect_value(t, valid_name("a-b_9"), true)
	testing.expect_value(t, valid_name("a.b"), false)
	testing.expect_value(t, valid_name(""), false)
	project, pane, ok := split_session("app.editor")
	testing.expect_value(t, project, "app")
	testing.expect_value(t, pane, "editor")
	testing.expect_value(t, ok, true)
	_, _, ok = split_session("plain")
	testing.expect_value(t, ok, false)
}

@(test)
test_quoting :: proc(t: ^testing.T) {
	shell := shell_quote("it's")
	defer delete(shell)
	testing.expect_value(t, shell, `'it'\''s'`)

	apple := applescript_string(`a "b" \c`)
	defer delete(apple)
	testing.expect_value(t, apple, `"a \"b\" \\c"`)
}

@(test)
test_open_script :: proc(t: ^testing.T) {
	text := "dir = /w\n[editor]\ncmd = nvim .\n[server]\ncmd = npm start\ntab = run\n[shell]\nsplit = down\n"
	p, err := parse_project("app", text, "right")
	defer delete_project(&p)

	testing.expect_value(t, err, "")
	script := build_open_script(p, "")
	defer delete(script)

	testing.expect_value(t, strings.count(script, "new tab in front window"), 2)
	testing.expect_value(t, strings.count(script, " to split "), 1)
	testing.expect(
		t,
		strings.contains(script, "set pane2 to split pane0 direction down with configuration cfg"),
	)
	testing.expect_value(t, strings.count(script, "equalize_splits"), 1)
	testing.expect_value(t, strings.count(script, "set initial input of cfg to"), 3)
	testing.expect(t, strings.contains(script, ` attach 'app.server'" & linefeed`))
	// shell shares the main tab with editor although it is listed after server
	editor := strings.index(script, "app.editor")
	shell := strings.index(script, "app.shell")
	server := strings.index(script, "app.server")
	testing.expect(t, editor < shell && shell < server)

	here := build_open_script(p, "/dev/ttys009")
	defer delete(here)

	testing.expect(
		t,
		strings.contains(here, `set pane0 to first terminal whose tty is "/dev/ttys009"`),
	)
	testing.expect_value(t, strings.count(here, "new tab in front window"), 1)
	testing.expect_value(t, strings.count(here, "set initial input of cfg to"), 2)
	testing.expect(t, !strings.contains(here, "app.editor"))
}

@(test)
test_open_script_from :: proc(t: ^testing.T) {
	text := "dir = /w\n[a]\n[b]\nsplit = down\n[c]\nfrom = a\n[d]\nfrom = gone\n"
	p, err := parse_project("app", text, "right")
	defer delete_project(&p)
	defer delete(err)

	testing.expect_value(t, err, "")

	script := build_open_script(p, "")
	defer delete(script)

	testing.expect(t, strings.contains(script, "set pane1 to split pane0 direction down"))
	testing.expect(t, strings.contains(script, "set pane2 to split pane0 direction right"))
	testing.expect(t, strings.contains(script, "set pane3 to split pane2 direction right"))
}

@(test)
test_insert_section :: proc(t: ^testing.T) {
	text := "dir = /w\n\n[a]\n\n[b]\ntab = run\n"

	result := insert_section(text, "[3]\ntab = 3\n", "b")
	testing.expect_value(t, result, "dir = /w\n\n[a]\n\n[3]\ntab = 3\n\n[b]\ntab = run\n")
	delete(result)

	result = insert_section(text, "[3]\ntab = 3\n", "")
	testing.expect_value(t, result, "dir = /w\n\n[a]\n\n[b]\ntab = run\n\n[3]\ntab = 3\n")
	delete(result)

	result = insert_section(text, "[3]\n", "gone")
	testing.expect_value(t, result, "dir = /w\n\n[a]\n\n[b]\ntab = run\n\n[3]\n")
	delete(result)

	result = insert_section("dir = /w", "[3]\n", "")
	testing.expect_value(t, result, "dir = /w\n\n[3]\n")
	delete(result)
}

@(test)
test_remove_section :: proc(t: ^testing.T) {
	text := "dir = /w\n\n[a]\n\n[ b ]\ntab = x\nsplit = down\n\n[c]\ncmd = ls\n"

	b := remove_section(text, "b")
	defer delete(b)
	testing.expect_value(t, b, "dir = /w\n\n[a]\n\n[c]\ncmd = ls\n")

	c := remove_section(text, "c")
	defer delete(c)
	testing.expect_value(t, c, "dir = /w\n\n[a]\n\n[ b ]\ntab = x\nsplit = down\n\n")

	gone := remove_section(text, "gone")
	defer delete(gone)
	testing.expect_value(t, gone, text)
}

@(test)
test_next_tab_pane :: proc(t: ^testing.T) {
	p, err := parse_project("app", "dir = /w\n[a]\n[b]\ntab = run\n[c]\n[d]\ntab = x\n", "right")
	defer delete_project(&p)

	testing.expect_value(t, err, "")
	testing.expect_value(t, next_tab_pane(p, "main"), "b")
	testing.expect_value(t, next_tab_pane(p, "run"), "d")
	testing.expect_value(t, next_tab_pane(p, "x"), "")
	testing.expect_value(t, next_tab_pane(p, "gone"), "")
}

@(test)
test_add_script :: proc(t: ^testing.T) {
	split := build_add_script("app.2", Pane{split = "down", dir = "/w"})
	defer delete(split)

	testing.expect(t, strings.contains(split, "split p direction down with configuration cfg"))
	testing.expect(t, !strings.contains(split, "new tab"))

	tab := build_add_script("app.3", Pane{dir = "/w"})
	defer delete(tab)

	testing.expect(t, strings.contains(tab, "new tab in front window with configuration cfg"))
	testing.expect(t, !strings.contains(tab, "split"))
	testing.expect(t, strings.contains(tab, ` attach 'app.3'" & linefeed`))
}

@(test)
test_pane_wrapper :: proc(t: ^testing.T) {
	w := pane_wrapper("npm start &")
	defer delete(w)

	testing.expect(t, strings.has_prefix(w, "trap \"exec "))
	testing.expect(t, strings.contains(w, "\" INT\nnpm start &\nexec "))
}
