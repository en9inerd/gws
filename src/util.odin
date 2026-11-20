package gws

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// core:fmt alone would double the binary size.
cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

itoa :: proc(n: int) -> string {
	buf := make([]u8, 24)
	return strconv.write_int(buf, i64(n), 10)
}

quote :: proc(s: string) -> string {
	return cat(`"`, s, `"`)
}

pad :: proc(s: string, width: int) -> string {
	if len(s) >= width {
		return cat(s, " ")
	}
	return cat(s, strings.repeat(" ", width - len(s) + 1))
}

say :: proc(parts: ..string) {
	os.write_string(os.stdout, cat(cat(..parts), "\n"))
}

fail :: proc(parts: ..string) -> ! {
	os.write_string(os.stderr, cat("gws: ", cat(..parts), "\n"))
	os.exit(1)
}

Run_Result :: struct {
	started: bool,
	ok:      bool,
	out:     string,
	err:     string,
}

run :: proc(command: []string, dir := "") -> Run_Result {
	state, out, err, e := os.process_exec(
		{command = command, working_dir = dir},
		context.allocator,
	)
	if e != nil {
		return {}
	}
	return {
		started = true,
		ok = state.exited && state.exit_code == 0,
		out = string(out),
		err = string(err),
	}
}

exec_cmd :: proc(argv: []string) -> ! {
	cargs := make([]cstring, len(argv) + 1)
	for a, i in argv {
		cargs[i] = strings.clone_to_cstring(a)
	}
	posix.execvp(cargs[0], raw_data(cargs))
	fail("cannot run ", argv[0], ": ", string(posix.strerror()))
}

get_env :: proc(key: string) -> string {
	return os.get_env(key, context.allocator)
}

shell_path :: proc() -> string {
	sh := get_env("SHELL")
	return sh if sh != "" else "/bin/sh"
}

expand_home :: proc(path: string) -> string {
	if path == "~" || strings.has_prefix(path, "~/") {
		return cat(get_env("HOME"), path[1:])
	}
	return path
}

collapse_home :: proc(path: string) -> string {
	home := get_env("HOME")
	if home != "" && (path == home || strings.has_prefix(path, cat(home, "/"))) {
		return cat("~", path[len(home):])
	}
	return path
}

shell_quote :: proc(s: string) -> string {
	quoted, _ := strings.replace_all(s, "'", `'\''`)
	return cat("'", quoted, "'")
}

applescript_string :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, `\`, `\\`)
	escaped, _ = strings.replace_all(escaped, `"`, `\"`)
	return quote(escaped)
}

name_char :: proc(c: u8) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' ||
		c == '-' \
	)
}

valid_name :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if !name_char(s[i]) {
			return false
		}
	}
	return len(s) > 0
}

sanitize_name :: proc(s: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(s) {
		c := s[i] if name_char(s[i]) else '_'
		if c == '_' && strings.has_suffix(strings.to_string(b), "_") {
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}
