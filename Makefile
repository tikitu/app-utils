# app-utils — small Swift libraries, one package.

.PHONY: check test fmt fmt-check lint help

help:
	@echo "  check      Compile every library"
	@echo "  test       Run every library's tests"
	@echo "  fmt        Reformat every Swift file in place"
	@echo "  fmt-check  Fail if any Swift file is not formatted"
	@echo "  lint       fmt-check (the non-compiling gate)"

check:
	swift build
	@echo "✓ compiles"

test:
	swift test
	@echo "✓ tests pass"

fmt:
	@swift format --configuration .swift-format --recursive --in-place Package.swift Sources Tests
	@echo "✓ formatted"

fmt-check:
	@swift format lint --configuration .swift-format --recursive --strict Package.swift Sources Tests \
	  && echo "✓ formatting clean"

lint: fmt-check
	@echo "✓ lint clean"
