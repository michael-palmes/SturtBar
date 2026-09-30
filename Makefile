SHELL := /bin/bash

.PHONY: build test run package dmg release lint format clean cost-audit

build:
	swift build

test:
	swift test

run:
	./Scripts/compile_and_run.sh

package:
	./Scripts/package_app.sh release

dmg: package
	./Scripts/make_dmg.sh

release:
	./Scripts/release.sh

lint:
	./Scripts/lint.sh lint

format:
	./Scripts/lint.sh format

cost-audit:
	swift Scripts/cost_audit.swift --codex

clean:
	swift package clean
	rm -rf dist .build/package .build/icon .build/dmg
