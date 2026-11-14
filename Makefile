EMACS ?= emacs
CARGO ?= cargo

# Emacs names its dynamic modules differently on each platform: .so on
# GNU/Linux, .dylib on macOS and .dll on Windows.
MODULE_SUFFIX = $(shell $(EMACS) -Q --batch --eval '(princ module-file-suffix)')
MODULE = jieba-bridge$(MODULE_SUFFIX)

ifeq ($(OS),Windows_NT)
LIBRARY = target/release/jieba_bridge.dll
else
LIBRARY = target/release/libjieba_bridge$(MODULE_SUFFIX)
endif

.PHONY: all build test test-rust test-el compile clean

all: build

# Build the dynamic module and copy it to where
# `emacs-jieba-rs-module-path' looks for it by default.
build:
	$(CARGO) build --release
	cp $(LIBRARY) $(MODULE)

test-rust:
	$(CARGO) test

test-el: build
	$(EMACS) -Q --batch -L . -l test/emacs-jieba-rs-tests.el \
	  -f ert-run-tests-batch-and-exit

test: test-rust test-el

compile: build
	$(EMACS) -Q --batch -L . -f batch-byte-compile emacs-jieba-rs.el

clean:
	$(CARGO) clean
	rm -f $(MODULE) emacs-jieba-rs.elc
