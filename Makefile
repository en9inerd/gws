ODIN    ?= odin
PREFIX  ?= $(HOME)/.local
BIN     := gws
# The git tag without its "v" (1.2.3, or 1.2.3-4-gabc1234 between tags), else "dev".
VERSION := $(or $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//'),dev)
DEFINES := -define:GWS_VERSION=$(VERSION)

.PHONY: build check test unit-test cli-test install uninstall clean

build:
	$(ODIN) build src -out:$(BIN) -o:size $(DEFINES)
	strip $(BIN)

check:
	$(ODIN) check src -vet -strict-style $(DEFINES)

test: unit-test cli-test

# One thread: some tests set environment variables.
unit-test:
	$(ODIN) test src -vet -strict-style -define:ODIN_TEST_TRACK_MEMORY=true -define:ODIN_TEST_THREADS=1 $(DEFINES)

cli-test: build
	sh tests/cli.sh ./$(BIN)

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)

clean:
	rm -rf $(BIN) odin-out dist
