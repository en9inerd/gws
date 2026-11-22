package gws

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

// Code under test never frees, like a gws run; the arena owns everything and is
// backed by the test's tracking allocator, so destroying it must leave nothing behind.
test_arena :: proc(arena: ^runtime.Arena) -> runtime.Allocator {
	_ = runtime.arena_init(arena, 0, context.allocator)
	return runtime.arena_allocator(arena)
}

// A new empty directory, as an absolute path without symlinks.
make_temp_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "gws-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	resolved, _ := os.get_absolute_path(dir, context.allocator)
	return resolved
}

remove_temp_dir :: proc(dir: string) {
	_ = os.remove_all(dir)
}

make_test_file :: proc(t: ^testing.T, path, text: string) {
	testing.expect_value(t, os.write_entire_file(path, text), nil)
}

make_test_dir :: proc(t: ^testing.T, path: string) {
	testing.expect_value(t, os.make_directory_all(path), nil)
}

// The value an environment variable had before set_test_env; restore_env puts it back.
Saved_Env :: struct {
	key:   string,
	value: string,
	found: bool,
}

set_test_env :: proc(key, value: string) -> Saved_Env {
	old, found := os.lookup_env(key, context.allocator)
	_ = os.set_env(key, value)
	return {key, old, found}
}

restore_env :: proc(saved: Saved_Env) {
	if saved.found {
		_ = os.set_env(saved.key, saved.value)
	} else {
		_ = os.unset_env(saved.key)
	}
}

@(test)
test_string_helpers :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	testing.expect_value(t, concat(), "")
	testing.expect_value(t, concat("a", "", "bc"), "abc")
	testing.expect_value(t, int_to_string(0), "0")
	testing.expect_value(t, int_to_string(-42), "-42")
	testing.expect_value(t, int_to_string(1234567), "1234567")
	testing.expect_value(t, quoted("x y"), `"x y"`)
	testing.expect_value(t, pad_right("", 2), "   ")
	testing.expect_value(t, pad_right("ab", 4), "ab   ")
	testing.expect_value(t, pad_right("abcd", 4), "abcd ")
	testing.expect_value(t, pad_right("abcdef", 4), "abcdef ")

	b := strings.builder_make()
	write_strings(&b, "a", "", "b")
	write_strings(&b)
	testing.expect_value(t, strings.to_string(b), "ab")
}

@(test)
test_quoting :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	testing.expect_value(t, shell_quote(""), "''")
	testing.expect_value(t, shell_quote("a b"), "'a b'")
	testing.expect_value(t, shell_quote("it's"), `'it'\''s'`)
	testing.expect_value(t, shell_quote("$HOME `x`"), "'$HOME `x`'")
	testing.expect_value(t, applescript_string(""), `""`)
	testing.expect_value(t, applescript_string(`a "b" \c`), `"a \"b\" \\c"`)
	testing.expect_value(t, applescript_string("é'"), `"é'"`)
}

@(test)
test_home_paths :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	home := get_env("HOME")
	if home == "" {
		return
	}
	testing.expect_value(t, expand_home("~"), home)
	testing.expect_value(t, expand_home("~/a/b"), concat(home, "/a/b"))
	testing.expect_value(t, expand_home("~user/a"), "~user/a")
	testing.expect_value(t, expand_home("/abs"), "/abs")
	testing.expect_value(t, expand_home("rel"), "rel")

	testing.expect_value(t, collapse_home(home), "~")
	testing.expect_value(t, collapse_home(concat(home, "/a")), "~/a")
	testing.expect_value(t, collapse_home(concat(home, "x/a")), concat(home, "x/a"))
	testing.expect_value(t, collapse_home("/elsewhere"), "/elsewhere")
	testing.expect_value(t, collapse_home(expand_home("~/x")), "~/x")
}

@(test)
test_shell_path :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	shell := get_env("SHELL")
	testing.expect_value(t, shell_path(), shell if shell != "" else "/bin/sh")
}

@(test)
test_run_process :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	result := run_process({"/bin/sh", "-c", "echo out; echo err >&2"})
	testing.expect(t, result.started && result.ok)
	testing.expect_value(t, result.stdout, "out\n")
	testing.expect_value(t, result.stderr, "err\n")

	result = run_process({"/bin/sh", "-c", "exit 3"})
	testing.expect(t, result.started && !result.ok)

	result = run_process({"/bin/sh", "-c", "pwd"}, "/")
	testing.expect_value(t, result.stdout, "/\n")

	result = run_process({"gws-no-such-command"})
	testing.expect(t, !result.started && !result.ok)
}

@(test)
test_files :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	dir := make_temp_dir(t)
	defer remove_temp_dir(dir)

	path := concat(dir, "/f.txt")
	write_file(path, "one\n")
	testing.expect_value(t, read_file(path), "one\n")
	write_file(path, "two")
	testing.expect_value(t, read_file(path), "two")

	// Writing through a symlink replaces the target and keeps the link.
	real := concat(dir, "/real.ini")
	link := concat(dir, "/link.ini")
	make_test_file(t, real, "old")
	testing.expect_value(t, os.symlink(real, link), nil)
	write_file(link, "new")
	testing.expect_value(t, read_file(real), "new")
	info, _ := os.lstat(link, context.allocator)
	testing.expect_value(t, info.type, os.File_Type.Symlink)

	// Permissions survive the replace.
	private_mode := os.Permissions{.Read_User, .Write_User}
	testing.expect_value(t, os.chmod(real, private_mode), nil)
	write_file(link, "newer")
	real_info, _ := os.stat(real, context.allocator)
	testing.expect_value(t, real_info.mode & os.Permissions_All, private_mode)

	files, _ := os.read_all_directory_by_path(dir, context.allocator)
	for file in files {
		testing.expectf(t, !strings.has_suffix(file.name, ".tmp"), "leftover temporary file %s", file.name)
	}

	make_test_dir(t, concat(dir, "/sub"))
	testing.expect_value(t, resolve_dir(dir), dir)
	testing.expect_value(t, resolve_dir(concat(dir, "/sub/..")), dir)
	testing.expect_value(t, resolve_dir(concat(dir, "/sub/")), concat(dir, "/sub"))
}
