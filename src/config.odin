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
	path:  string, // the project file
	panes: [dynamic]Pane,
}

Search_Path :: struct {
	path:  string,
	depth: int, // 0 = Config.search_depth
}

// ~/.config/gws/config.ini
Config :: struct {
	search_paths:  [dynamic]Search_Path,
	search_depth:  int,
	default_split: string,
}

// Names and paths.

NAME_RULE :: " (use A-Z a-z 0-9 _ -)"
SPLIT_ERROR :: "split must be right, left, down or up"

is_name_char :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		return true
	}
	return false
}

is_valid_name :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if !is_name_char(s[i]) {
			return false
		}
	}
	return len(s) > 0
}

// Replaces each run of characters not allowed in names with one '_'.
sanitize_name :: proc(s: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(s) {
		c := s[i] if is_name_char(s[i]) else '_'
		if c == '_' && strings.has_suffix(strings.to_string(b), "_") {
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

is_valid_split :: proc(s: string) -> bool {
	switch s {
	case "right", "left", "down", "up":
		return true
	}
	return false
}

session_name :: proc(project_name, pane_name: string) -> string {
	return concat(project_name, ".", pane_name)
}

// "myapp.editor" -> "myapp", "editor". Project names cannot contain '.'.
split_session_name :: proc(session: string) -> (project_name, pane_name: string, ok: bool) {
	i := strings.index_byte(session, '.')
	if i <= 0 || i == len(session) - 1 {
		return session, "", false
	}
	return session[:i], session[i + 1:], true
}

config_dir :: proc() -> string {
	base := get_env("XDG_CONFIG_HOME")
	if base == "" {
		base = concat(get_env("HOME"), "/.config")
	}
	return concat(base, "/gws")
}

projects_dir :: proc() -> string {
	return concat(config_dir(), "/projects")
}

project_path :: proc(name: string) -> string {
	return concat(projects_dir(), "/", name, ".ini")
}

project_exists :: proc(name: string) -> bool {
	return is_valid_name(name) && os.is_file(project_path(name))
}

project_names :: proc() -> []string {
	files, err := os.read_all_directory_by_path(projects_dir(), context.allocator)
	if err != nil {
		return nil
	}
	names: [dynamic]string
	for file in files {
		if file.type == .Regular && strings.has_suffix(file.name, ".ini") {
			append(&names, strings.trim_suffix(file.name, ".ini"))
		}
	}
	slice.sort(names[:])
	return names[:]
}

// INI parsing.

Ini_Entry :: struct {
	line:       int,
	is_section: bool,
	key:        string, // the section name when is_section
	value:      string,
}

line_error :: proc(line: int, parts: ..string) -> string {
	return concat("line ", int_to_string(line), ": ", concat(..parts))
}

// `[section]`, `key = value`, whole-line `;`/`#` comments. Unlike core:encoding/ini's
// iterator, sections with no keys are kept: a bare `[shell]` is a valid pane.
parse_ini :: proc(text: string) -> (entries: [dynamic]Ini_Entry, err: string) {
	rest := text
	line_number := 0
	for raw_line in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if line == "" || line[0] == ';' || line[0] == '#' {
			continue
		}

		if line[0] == '[' {
			if !strings.has_suffix(line, "]") {
				return {}, line_error(line_number, "missing ']'")
			}
			name := strings.trim_space(line[1:len(line) - 1])
			append(&entries, Ini_Entry{line = line_number, is_section = true, key = name})
			continue
		}

		key, eq, value := strings.partition(line, "=")
		if eq == "" {
			return {}, line_error(line_number, "expected 'key = value'")
		}
		value = strings.trim_space(value)
		if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
			if unquoted, _, ok := strconv.unquote_string(value); ok {
				value = unquoted
			}
		}
		append(
			&entries,
			Ini_Entry{line = line_number, key = strings.trim_space(key), value = value},
		)
	}
	return entries, ""
}

// The returned project's strings point into text.
parse_project :: proc(name, text, default_split: string) -> (project: Project, err: string) {
	project.name = name
	entries, ini_err := parse_ini(text)
	if ini_err != "" {
		return project, ini_err
	}

	for entry in entries {
		if entry.is_section {
			if !is_valid_name(entry.key) {
				return project, line_error(
					entry.line,
					"invalid pane name ",
					quoted(entry.key),
					NAME_RULE,
				)
			}
			if _, duplicate := find_pane(project, entry.key); duplicate {
				return project, line_error(entry.line, "duplicate pane ", quoted(entry.key))
			}
			append(&project.panes, Pane{name = entry.key, tab = "main", split = default_split})
			continue
		}

		// Keys before the first section belong to the project.
		if len(project.panes) == 0 {
			if entry.key != "dir" {
				return project, line_error(entry.line, "unknown project key ", quoted(entry.key))
			}
			project.dir = expand_home(entry.value)
			continue
		}

		pane := &project.panes[len(project.panes) - 1]
		switch entry.key {
		case "cmd":
			pane.cmd = entry.value
		case "tab":
			if !is_valid_name(entry.value) {
				return project, line_error(entry.line, "invalid tab name ", quoted(entry.value))
			}
			pane.tab = entry.value
		case "split":
			if !is_valid_split(entry.value) {
				return project, line_error(entry.line, SPLIT_ERROR)
			}
			pane.split = entry.value
		case "from":
			if !is_valid_name(entry.value) {
				return project, line_error(entry.line, "invalid pane name ", quoted(entry.value))
			}
			pane.from = entry.value
		case "dir":
			pane.dir = expand_home(entry.value)
		case:
			return project, line_error(entry.line, "unknown pane key ", quoted(entry.key))
		}
	}

	if project.dir == "" {
		return project, "missing 'dir = ...'"
	}
	if !strings.has_prefix(project.dir, "/") {
		return project, "dir must be absolute or start with ~/"
	}
	for &pane in project.panes {
		if pane.dir == "" {
			pane.dir = project.dir
		} else if !strings.has_prefix(pane.dir, "/") {
			pane.dir = concat(project.dir, "/", pane.dir)
		}
	}
	return project, ""
}

parse_config :: proc(text: string, config: ^Config) -> string {
	entries, err := parse_ini(text)
	if err != "" {
		return err
	}

	for entry in entries {
		if entry.is_section {
			return line_error(entry.line, "sections are not used in config.ini")
		}
		switch entry.key {
		case "search":
			// "path" or "path:depth"
			search := Search_Path {
				path = entry.value,
			}
			if i := strings.last_index_byte(entry.value, ':'); i > 0 {
				if depth, ok := strconv.parse_int(entry.value[i + 1:]); ok && depth > 0 {
					search = {
						path  = entry.value[:i],
						depth = depth,
					}
				}
			}
			search.path = expand_home(search.path)
			if !strings.has_prefix(search.path, "/") {
				return line_error(entry.line, "search must be absolute or start with ~/")
			}
			append(&config.search_paths, search)
		case "depth":
			depth, ok := strconv.parse_int(entry.value)
			if !ok || depth < 1 {
				return line_error(entry.line, "depth must be a positive number")
			}
			config.search_depth = depth
		case "split":
			if !is_valid_split(entry.value) {
				return line_error(entry.line, SPLIT_ERROR)
			}
			config.default_split = entry.value
		case:
			return line_error(entry.line, "unknown key ", quoted(entry.key))
		}
	}
	return ""
}

// Loading.

default_config :: proc() -> Config {
	return {search_depth = 1, default_split = "right"}
}

// The defaults when config.ini does not exist; exits when it is invalid.
load_config :: proc() -> Config {
	config := default_config()
	path := concat(config_dir(), "/config.ini")
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		if parse_err := parse_config(string(data), &config); parse_err != "" {
			fail(path, ": ", parse_err)
		}
	}
	if len(config.search_paths) == 0 {
		append(&config.search_paths, Search_Path{path = expand_home("~/Development")})
	}
	return config
}

try_load_project :: proc(name: string, config: Config) -> (project: Project, err: string) {
	if !is_valid_name(name) {
		return project, concat("invalid project name ", quoted(name))
	}
	path := project_path(name)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return project, concat(
			"project ",
			quoted(name),
			" not found (create it: gws new ",
			name,
			")",
		)
	}
	project, err = parse_project(name, string(data), config.default_split)
	if err != "" {
		return project, concat(path, ": ", err)
	}
	project.path = path
	return project, ""
}

// Exits when the project is missing or invalid.
load_project :: proc(name: string, config: Config) -> Project {
	project, err := try_load_project(name, config)
	if err != "" {
		fail(err)
	}
	return project
}

find_pane :: proc(project: Project, name: string) -> (^Pane, bool) {
	for &pane in project.panes {
		if pane.name == name {
			return &pane, true
		}
	}
	return nil, false
}

// Editing project files.

new_project_text :: proc(dir: string) -> string {
	return concat("dir = ", dir, "\n\n[shell]\n")
}

// A new pane may not reuse a pane or tab name, nor attach to a leftover live session.
is_pane_name_free :: proc(project: Project, sessions: []Session, name: string) -> bool {
	if _, is_pane := find_pane(project, name); is_pane {
		return false
	}
	for pane in project.panes {
		if pane.tab == name {
			return false
		}
	}
	return !is_session_live(sessions, session_name(project.name, name))
}

// The smallest free number from 2 up.
next_pane_name :: proc(project: Project, sessions: []Session) -> string {
	for n := 2;; n += 1 {
		if name := int_to_string(n); is_pane_name_free(project, sessions, name) {
			return name
		}
	}
}

// The first pane of the tab after `tab`, or "". Ghostty opens a new tab right after the
// current one, so a new tab's section goes before this pane.
first_pane_of_next_tab :: proc(project: Project, tab: string) -> string {
	seen_tabs: map[string]bool
	for pane in project.panes {
		if seen_tabs[tab] && !seen_tabs[pane.tab] {
			return pane.name
		}
		seen_tabs[pane.tab] = true
	}
	return ""
}

// The section gws writes for a pane it adds; optional keys only when they are set.
pane_section :: proc(project: Project, pane: Pane) -> string {
	b := strings.builder_make()
	write_strings(&b, "[", pane.name, "]\ntab = ", pane.tab, "\n")
	if pane.split != "" {
		write_strings(&b, "split = ", pane.split, "\n")
	}
	if pane.from != "" {
		write_strings(&b, "from = ", pane.from, "\n")
	}
	if pane.dir != project.dir {
		write_strings(&b, "dir = ", collapse_home(pane.dir), "\n")
	}
	return strings.to_string(b)
}

// Inserts section before the `[before]` header, or at the end when there is none.
insert_section :: proc(text, section, before: string) -> string {
	b := strings.builder_make()
	rest := text
	inserted := false
	for line in strings.split_lines_after_iterator(&rest) {
		if name, ok := section_header(line); ok && name == before {
			write_strings(&b, section, "\n")
			inserted = true
		}
		strings.write_string(&b, line)
	}
	if !inserted {
		if len(text) > 0 && !strings.has_suffix(text, "\n") {
			strings.write_byte(&b, '\n')
		}
		write_strings(&b, "\n", section)
	}
	return strings.to_string(b)
}

// Drops the lines from the `[name]` header up to the next section.
remove_section :: proc(text, name: string) -> string {
	b := strings.builder_make()
	rest := text
	skipping := false
	for line in strings.split_lines_after_iterator(&rest) {
		if header, ok := section_header(line); ok {
			skipping = header == name
		}
		if !skipping {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b)
}

// The name in a `[name]` line.
section_header :: proc(line: string) -> (name: string, ok: bool) {
	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "[") {
		return "", false
	}
	return strings.trim_space(strings.trim_suffix(trimmed, "]")[1:]), true
}
