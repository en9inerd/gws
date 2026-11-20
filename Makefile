ODIN   ?= odin
PREFIX ?= $(HOME)/.local
BIN    := gws

.PHONY: build check test install uninstall clean

build:
	$(ODIN) build src -out:$(BIN) -o:size
	strip $(BIN)

check:
	$(ODIN) check src -vet -strict-style

test:
	$(ODIN) test src -define:ODIN_TEST_TRACK_MEMORY=false

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)
