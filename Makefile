# Makefile for the Vinculum example plugin.
#
# `build` / `smoke` are for LOCAL development and rely on the gitignored
# go.work that points at ../vinculum, so the plugin and the host binary
# are compiled from the identical local vinculum source (required for the
# ABI-sensitive Go plugin loader).
#
# `docker-build` is the DEPLOYMENT path: it builds the .so against the
# released vinculum module inside the matching vinculum-build image.

PLUGIN      := example
SO          := $(PLUGIN).so
# The vinculum-build / runtime image tag for the deployment build is derived
# from the version pinned in go.mod, so go.mod is the single source of truth:
# bump the require there (manually or via Renovate/Dependabot) and `make
# docker-build` + CI all follow. Override on the command line if needed.
# (The container plugin workflow requires the cgo-enabled images, vinculum
# >= 0.37.1.)
VINCULUM_VERSION ?= $(shell grep -E '^[[:space:]]*github.com/tsarna/vinculum ' go.mod | awk '{print $$2}' | sed 's/^v//')
SMOKE_DIR   := /tmp/vinc-smoke

.PHONY: build docker-build smoke clean

# NOTE: build flags (notably -trimpath) MUST match between the plugin and
# the host binary, or plugin.Open fails with "different version of package
# internal/goarch". The local targets below build neither with -trimpath;
# docker-build uses -trimpath to match the released, trimpath-built runtime.

## build: compile the plugin locally (uses go.work -> ../vinculum)
build:
	go build -buildmode=plugin -o $(SO) .

## docker-build: compile the plugin for deployment against a released vinculum
## (uses the bundled wrapper, which enforces flags/toolchain and fails fast
## on shared-dependency drift). Requires go.mod to require v$(VINCULUM_VERSION).
docker-build:
	docker run --rm \
		-v "$(CURDIR)":/plugin -w /plugin \
		ghcr.io/tsarna/vinculum-build:$(VINCULUM_VERSION) \
		vinculum-plugin-build -o $(SO) .

## smoke: build a host binary + the plugin from local source and run `vinculum check`
smoke:
	@mkdir -p $(SMOKE_DIR)/plugins
	go vet ./...
	go build -o $(SMOKE_DIR)/vinculum github.com/tsarna/vinculum
	go build -buildmode=plugin -o $(SMOKE_DIR)/plugins/$(SO) .
	$(SMOKE_DIR)/vinculum check --plugin-path $(SMOKE_DIR)/plugins examples/
	@echo "smoke test passed"

## clean: remove build artifacts
clean:
	rm -f $(SO)
	rm -rf $(SMOKE_DIR)
