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
VINCULUM_VERSION ?= 0.36.0
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
docker-build:
	docker run --rm \
		-v "$(CURDIR)":/plugin -w /plugin \
		ghcr.io/tsarna/vinculum-build:$(VINCULUM_VERSION) \
		go build -buildmode=plugin -trimpath -o $(SO) .

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
