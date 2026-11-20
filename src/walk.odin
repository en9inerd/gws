package gws

import "core:os"
import "core:slice"
import "core:strings"

// Directories under root up to depth levels, sorted, skipping hidden ones and symlinks.
walk_dirs :: proc(root: string, depth: int, out: ^[dynamic]string) {
	if depth <= 0 {
		return
	}
	infos, e := os.read_all_directory_by_path(root, context.allocator)
	if e != nil {
		return
	}
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for fi in infos {
		if fi.type != .Directory || strings.has_prefix(fi.name, ".") {
			continue
		}
		append(out, fi.fullpath)
		walk_dirs(fi.fullpath, depth - 1, out)
	}
}
