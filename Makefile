BIN     := macro_keyboard
PREFIX  ?= /usr/local
BINDIR  := $(DESTDIR)$(PREFIX)/bin
UDEVDIR := /etc/udev/rules.d
RULE    := 99-macro-keyboard.rules

.PHONY: all build run fmt clean install uninstall install-udev

all: build

build:
	v -o $(BIN) .

run: build
	./$(BIN) info

fmt:
	v fmt -w *.v

clean:
	rm -f $(BIN)

install: build
	install -Dm755 $(BIN) $(BINDIR)/$(BIN)

uninstall:
	rm -f $(BINDIR)/$(BIN)

# Install the udev rule for non-root access (needs sudo). Replug after running.
install-udev:
	install -m644 $(RULE) $(UDEVDIR)/$(RULE)
	udevadm control --reload
	udevadm trigger
