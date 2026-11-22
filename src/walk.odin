package gws

import "core:os"
import "core:slice"
import "core:strings"

// Appends directories under root up to depth levels, sorted, skipping hidden ones and symlinks.
walk_dirs :: proc(root: string, depth: int, out: ^[dynamic]string) {
	if depth <= 0 {
		return
	}
	entries, err := os.read_all_directory_by_path(root, context.allocator)
	if err != nil {
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.type != .Directory || strings.has_prefix(entry.name, ".") {
			continue
		}
		append(out, entry.fullpath)
		walk_dirs(entry.fullpath, depth - 1, out)
	}
}
