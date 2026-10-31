.PHONY: all build build-all install install-all uninstall clean help

all: build

build:
	./fedora-build.sh

build-all:
	./fedora-build.sh --all

install:
	sudo ./fedora-install.sh

install-all:
	sudo ./fedora-install.sh --all

uninstall:
	sudo ./fedora-uninstall.sh

uninstall-all:
	sudo ./fedora-uninstall.sh --all

clean:
	rm -rf build .cache

help:
	@echo "iwlwifi-lar-patched for Fedora Makefile targets:"
	@echo "  make              - Build modules for currently running kernel"
	@echo "  make build-all    - Build modules for all installed kernel-devel versions"
	@echo "  sudo make install - Install & sign modules for currently running kernel"
	@echo "  sudo make install-all - Install & sign modules for all built versions"
	@echo "  sudo make uninstall   - Remove modules and restore default driver"
	@echo "  make clean        - Clean build artifacts and cache"

