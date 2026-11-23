package gws

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// String building and output. core:fmt alone would double the binary size.

concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

write_strings :: proc(b: ^strings.Builder, parts: ..string) {
	for part in parts {
		strings.write_string(b, part)
	}
}

int_to_string :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10))
}

quoted :: proc(s: string) -> string {
	return concat(`"`, s, `"`)
}

// s padded with spaces to width, always followed by at least one space.
pad_right :: proc(s: string, width: int) -> string {
	return concat(s, strings.repeat(" ", max(width - len(s), 0) + 1))
}

print_line :: proc(parts: ..string) {
	os.write_string(os.stdout, concat(concat(..parts), "\n"))
}

fail :: proc(parts: ..string) -> ! {
	os.write_string(os.stderr, concat("gws: ", concat(..parts), "\n"))
	os.exit(1)
}

// Processes and environment.

Process_Result :: struct {
	started: bool,
	ok:      bool, // exited with status 0
	stdout:  string,
	stderr:  string,
}

run_process :: proc(command: []string, dir := "") -> Process_Result {
	state, stdout, stderr, err := os.process_exec(
		{command = command, working_dir = dir},
		context.allocator,
	)
	if err != nil {
		return {}
	}
	return {
		started = true,
		ok = state.exited && state.exit_code == 0,
		stdout = string(stdout),
		stderr = string(stderr),
	}
}

// Replaces this process with command; returns only by failing.
replace_process :: proc(command: []string) -> ! {
	argv := make([]cstring, len(command) + 1)
	for arg, i in command {
		argv[i] = strings.clone_to_cstring(arg)
	}

	posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
	posix.execvp(argv[0], raw_data(argv))
	fail("cannot run ", command[0], ": ", string(posix.strerror()))
}

get_env :: proc(key: string) -> string {
	return os.get_env(key, context.allocator)
}

shell_path :: proc() -> string {
	shell := get_env("SHELL")
	return shell if shell != "" else "/bin/sh"
}

// Paths and files.

expand_home :: proc(path: string) -> string {
	if path == "~" || strings.has_prefix(path, "~/") {
		return concat(get_env("HOME"), path[1:])
	}
	return path
}

collapse_home :: proc(path: string) -> string {
	home := get_env("HOME")
	if home != "" && (path == home || strings.has_prefix(path, concat(home, "/"))) {
		return concat("~", path[len(home):])
	}
	return path
}

// An existing directory as an absolute path, with `~` expanded; exits otherwise.
resolve_dir :: proc(path: string) -> string {
	dir, err := os.get_absolute_path(expand_home(path), context.allocator)
	if err != nil || !os.is_dir(dir) {
		fail("not a directory: ", path)
	}
	return dir
}

// Exits on error.
read_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fail("cannot read ", path, ": ", os.error_string(err))
	}
	return string(data)
}

// Replaces the file in one step (temporary file, then rename), so a failed write never
// leaves it half written. A symlink stays a symlink: its target is replaced, keeping its
// permissions. Exits on error.
write_file :: proc(path, text: string) {
	target := path
	if resolved, err := os.get_absolute_path(path, context.allocator); err == nil {
		target = resolved
	}
	permissions := os.Permissions_Read_All + {.Write_User}
	if info, err := os.stat(target, context.allocator); err == nil {
		permissions = info.mode
	}
	// Unique per process: two gws commands may edit the same project at once.
	temp := concat(target, ".", int_to_string(os.get_pid()), ".tmp")
	err := os.write_entire_file(temp, text, permissions)
	if err == nil {
		err = os.rename(temp, target)
	}
	if err != nil {
		_ = os.remove(temp)
		fail("cannot write ", path, ": ", os.error_string(err))
	}
}

// Quoting.

shell_quote :: proc(s: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '\'')
	for c in s {
		if c == '\'' {
			strings.write_string(&b, `'\''`)
		} else {
			strings.write_rune(&b, c)
		}
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

applescript_string :: proc(s: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '"')
	for c in s {
		switch c {
		case '\\':
			strings.write_string(&b, `\\`)
		case '"':
			strings.write_string(&b, `\"`)
		case:
			strings.write_rune(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}
