package gws

import "base:runtime"
import "core:log"
import "core:testing"

// fzf --filter matches without a terminal, so the pipes to and from fzf can be tested.
@(test)
test_fzf :: proc(t: ^testing.T) {
	arena: runtime.Arena
	context.allocator = test_arena(&arena)
	defer runtime.arena_destroy(&arena)

	if !run_process({"fzf", "--version"}).started {
		log.warn("fzf not installed; skipped")
		return
	}

	output, exit_code := fzf({"alpha", "beta", "gamma"}, "--filter=bet")
	testing.expect_value(t, exit_code, 0)
	testing.expect_value(t, len(output), 1)
	testing.expect_value(t, output[0], "beta")

	output, exit_code = fzf({"alpha", "beta"}, "--filter=zzz")
	testing.expect_value(t, exit_code, FZF_NO_MATCH)
	testing.expect_value(t, len(output), 1)
	testing.expect_value(t, output[0], "")

	output, exit_code = fzf({"ab", "abc"}, "--filter=ab", "--no-sort")
	testing.expect_value(t, len(output), 2)

	output, exit_code = fzf({"query line"}, "--filter=query", "--print-query")
	testing.expect_value(t, len(output), 2)
	testing.expect_value(t, output[0], "query")
	testing.expect_value(t, output[1], "query line")
}
