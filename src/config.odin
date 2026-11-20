package gws

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Pane :: struct {
	name:  string,
	cmd:   string,
	tab:   string,
	split: string,
	from:  string,
	dir:   string,
}

Project :: struct {
	name:  string,
	dir:   string,
	path:  string,
	panes: [dynamic]Pane,
}

Search_Path :: struct {
	path:  string,
	depth: int, // 0 = use Global.depth
}

Global :: struct {
	search: [dynamic]Search_Path,
	depth:  int,
	split:  string,
}

Ini_Entry :: struct {
	line:       int,
	is_section: bool,
	key:        string, // section name when is_section
	value:      string,
}

line_error :: proc(line: int, parts: ..string) -> string {
	return cat("line ", itoa(line), ": ", cat(..parts))
}

// `[section]`, `key = value`, whole-line `;`/`#` comments. Unlike core:encoding/ini's
// iterator, sections with no keys are kept: a bare `[shell]` is a valid pane.
parse_ini :: proc(text: string) -> (entries: [dynamic]Ini_Entry, err: string) {
	rest := text
	n := 0
	for raw in strings.split_lines_iterator(&rest) {
		n += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == ';' || line[0] == '#' {
			continue
		}
		if line[0] == '[' {
			if !strings.has_suffix(line, "]") {
				return entries, line_error(n, "missing ']'")
			}
			append(
				&entries,
				Ini_Entry {
					line = n,
					is_section = true,
					key = strings.trim_space(line[1:len(line) - 1]),
				},
			)
			continue
		}
		key, eq, value := strings.partition(line, "=")
		if eq == "" {
			return entries, line_error(n, "expected 'key = value'")
		}
		value = strings.trim_space(value)
		if len(value) >= 2 && value[0] == '"' {
			if s, _, ok := strconv.unquote_string(value); ok {
				value = s
			}
		}
		append(&entries, Ini_Entry{line = n, key = strings.trim_space(key), value = value})
	}
	return entries, ""
}

valid_split :: proc(s: string) -> bool {
	switch s {
	case "right", "left", "down", "up":
		return true
	}
	return false
}

parse_project :: proc(name, text, default_split: string) -> (p: Project, err: string) {
	p.name = name
	entries, ini_err := parse_ini(text)
	if ini_err != "" {
		return p, ini_err
	}
	for e in entries {
		if e.is_section {
			if !valid_name(e.key) {
				return p, line_error(
					e.line,
					"invalid pane name ",
					quote(e.key),
					" (use A-Z a-z 0-9 _ -)",
				)
			}
			for q in p.panes {
				if q.name == e.key {
					return p, line_error(e.line, "duplicate pane ", quote(e.key))
				}
			}
			append(&p.panes, Pane{name = e.key, tab = "main", split = default_split})
			continue
		}
		if len(p.panes) == 0 {
			switch e.key {
			case "dir":
				p.dir = expand_home(e.value)
			case:
				return p, line_error(e.line, "unknown project key ", quote(e.key))
			}
			continue
		}
		pane := &p.panes[len(p.panes) - 1]
		switch e.key {
		case "cmd":
			pane.cmd = e.value
		case "tab":
			if !valid_name(e.value) {
				return p, line_error(e.line, "invalid tab name ", quote(e.value))
			}
			pane.tab = e.value
		case "split":
			if !valid_split(e.value) {
				return p, line_error(e.line, "split must be right, left, down or up")
			}
			pane.split = e.value
		case "from":
			if !valid_name(e.value) {
				return p, line_error(e.line, "invalid pane name ", quote(e.value))
			}
			pane.from = e.value
		case "dir":
			pane.dir = expand_home(e.value)
		case:
			return p, line_error(e.line, "unknown pane key ", quote(e.key))
		}
	}
	if p.dir == "" {
		return p, "missing 'dir = ...'"
	}
	if !strings.has_prefix(p.dir, "/") {
		return p, "dir must be absolute or start with ~/"
	}
	for &pane in p.panes {
		if pane.dir == "" {
			pane.dir = p.dir
		} else if !strings.has_prefix(pane.dir, "/") {
			pane.dir = cat(p.dir, "/", pane.dir)
		}
	}
	return p, ""
}

parse_global :: proc(text: string, g: ^Global) -> string {
	entries, ini_err := parse_ini(text)
	if ini_err != "" {
		return ini_err
	}
	for e in entries {
		if e.is_section {
			return line_error(e.line, "sections are not used in config.ini")
		}
		switch e.key {
		case "search":
			sp := Search_Path {
				path = e.value,
			}
			if i := strings.last_index_byte(e.value, ':'); i > 0 {
				if d, ok := strconv.parse_int(e.value[i + 1:]); ok && d > 0 {
					sp = {
						path  = e.value[:i],
						depth = d,
					}
				}
			}
			sp.path = expand_home(sp.path)
			if !strings.has_prefix(sp.path, "/") {
				return line_error(e.line, "search must be absolute or start with ~/")
			}
			append(&g.search, sp)
		case "depth":
			d, ok := strconv.parse_int(e.value)
			if !ok || d < 1 {
				return line_error(e.line, "depth must be a positive number")
			}
			g.depth = d
		case "split":
			if !valid_split(e.value) {
				return line_error(e.line, "split must be right, left, down or up")
			}
			g.split = e.value
		case:
			return line_error(e.line, "unknown key ", quote(e.key))
		}
	}
	return ""
}

config_dir :: proc() -> string {
	base := get_env("XDG_CONFIG_HOME")
	if base == "" {
		base = cat(get_env("HOME"), "/.config")
	}
	return cat(base, "/gws")
}

projects_dir :: proc() -> string {
	return cat(config_dir(), "/projects")
}

project_path :: proc(name: string) -> string {
	return cat(projects_dir(), "/", name, ".ini")
}

project_exists :: proc(name: string) -> bool {
	return valid_name(name) && os.is_file(project_path(name))
}

load_global :: proc() -> Global {
	g := Global {
		depth = 1,
		split = "right",
	}
	path := cat(config_dir(), "/config.ini")
	if data, e := os.read_entire_file(path, context.allocator); e == nil {
		if err := parse_global(string(data), &g); err != "" {
			fail(path, ": ", err)
		}
	}
	if len(g.search) == 0 {
		append(&g.search, Search_Path{path = expand_home("~/Development")})
	}
	return g
}

try_load_project :: proc(name: string, g: Global) -> (p: Project, err: string) {
	if !valid_name(name) {
		return p, cat("invalid project name ", quote(name))
	}
	path := project_path(name)
	data, e := os.read_entire_file(path, context.allocator)
	if e != nil {
		return p, cat("project ", quote(name), " not found (create it: gws new ", name, ")")
	}
	p, err = parse_project(name, string(data), g.split)
	if err != "" {
		return p, cat(path, ": ", err)
	}
	p.path = path
	return p, ""
}

load_project :: proc(name: string, g: Global) -> Project {
	p, err := try_load_project(name, g)
	if err != "" {
		fail(err)
	}
	return p
}

project_names :: proc() -> []string {
	infos, e := os.read_all_directory_by_path(projects_dir(), context.allocator)
	if e != nil {
		return nil
	}
	names: [dynamic]string
	for fi in infos {
		if fi.type == .Regular && strings.has_suffix(fi.name, ".ini") {
			append(&names, strings.trim_suffix(fi.name, ".ini"))
		}
	}
	slice.sort(names[:])
	return names[:]
}

find_pane :: proc(p: Project, name: string) -> (^Pane, bool) {
	for &pane in p.panes {
		if pane.name == name {
			return &pane, true
		}
	}
	return nil, false
}

session_name :: proc(project, pane: string) -> string {
	return cat(project, ".", pane)
}

// "myapp.editor" -> "myapp", "editor". Project names cannot contain '.'.
split_session :: proc(s: string) -> (project, pane: string, ok: bool) {
	i := strings.index_byte(s, '.')
	if i <= 0 || i == len(s) - 1 {
		return s, "", false
	}
	return s[:i], s[i + 1:], true
}

new_project_text :: proc(dir: string) -> string {
	return cat("dir = ", dir, "\n\n[shell]\n")
}

// The first pane of the tab after `tab`, or "". Ghostty opens a new tab right after the
// current one, so a new tab's section goes before this pane.
next_tab_pane :: proc(p: Project, tab: string) -> string {
	seen: map[string]bool
	for q in p.panes {
		if seen[tab] && !seen[q.tab] {
			return q.name
		}
		seen[q.tab] = true
	}
	return ""
}

// Writes the pane's section before the `[before]` header, or at the end when there is none.
insert_pane :: proc(p: Project, pane: Pane, before: string) -> os.Error {
	data := os.read_entire_file(p.path, context.allocator) or_return
	section := cat("[", pane.name, "]\ntab = ", pane.tab, "\n")
	if pane.split != "" {
		section = cat(section, "split = ", pane.split, "\n")
	}
	if pane.from != "" {
		section = cat(section, "from = ", pane.from, "\n")
	}
	if pane.dir != p.dir {
		section = cat(section, "dir = ", pane.dir, "\n")
	}
	return os.write_entire_file(p.path, insert_section(string(data), section, before))
}

insert_section :: proc(text, section, before: string) -> string {
	b := strings.builder_make()
	rest := text
	inserted := false
	for line in strings.split_lines_after_iterator(&rest) {
		if name, ok := section_name(line); ok && name == before {
			strings.write_string(&b, cat(section, "\n"))
			inserted = true
		}
		strings.write_string(&b, line)
	}
	if !inserted {
		if len(text) > 0 && !strings.has_suffix(text, "\n") {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, cat("\n", section))
	}
	return strings.to_string(b)
}

// Drops the lines from the pane's `[name]` header up to the next section.
remove_section :: proc(text, name: string) -> string {
	b := strings.builder_make()
	rest := text
	skip := false
	for line in strings.split_lines_after_iterator(&rest) {
		if header, ok := section_name(line); ok {
			skip = header == name
		}
		if !skip {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b)
}

section_name :: proc(line: string) -> (string, bool) {
	t := strings.trim_space(line)
	if !strings.has_prefix(t, "[") {
		return "", false
	}
	return strings.trim_space(strings.trim_suffix(t, "]")[1:]), true
}
