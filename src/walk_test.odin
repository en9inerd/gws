package gws

import "base:runtime"
import "core:os"
import "core:slice"
import "core:testing"

@(test)
test_walk_dirs :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	root := make_temp_dir(t)
	defer remove_temp_dir(root)

	make_test_dir(t, concat(root, "/b/deep/deeper"))
	make_test_dir(t, concat(root, "/a"))
	make_test_dir(t, concat(root, "/.hidden/inside"))
	make_test_file(t, concat(root, "/file"), "")
	testing.expect_value(t, os.symlink(concat(root, "/a"), concat(root, "/link")), nil)

	walk :: proc(root: string, depth: int) -> []string {
		dirs: [dynamic]string
		walk_dirs(root, depth, &dirs)
		return dirs[:]
	}

	testing.expect_value(t, len(walk(root, 0)), 0)
	got := walk(root, 1)
	testing.expectf(t, slice.equal(got, []string{concat(root, "/a"), concat(root, "/b")}), "depth 1: %v", got)
	got = walk(root, 2)
	want := []string{concat(root, "/a"), concat(root, "/b"), concat(root, "/b/deep")}
	testing.expectf(t, slice.equal(got, want), "depth 2: %v", got)
	testing.expect_value(t, len(walk(root, 10)), 4)
	testing.expect_value(t, len(walk(concat(root, "/missing"), 3)), 0)

	// Appends after what is already there.
	dirs: [dynamic]string
	append(&dirs, "first")
	walk_dirs(root, 1, &dirs)
	testing.expect_value(t, len(dirs), 3)
	testing.expect_value(t, dirs[0], "first")
}
