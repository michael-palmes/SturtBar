SHELL := /bin/bash

.PHONY: build test run package release lint format clean

build:
	swift build

test:
	swift test

run:
	./Scripts/compile_and_run.sh

package:
	./Scripts/package_app.sh release

release:
	./Scripts/release.sh

lint:
	./Scripts/lint.sh lint

format:
	./Scripts/lint.sh format

clean:
	swift package clean
	rm -rf dist .build/package .build/icon
