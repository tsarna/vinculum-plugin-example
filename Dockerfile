# Example deployment image: a Vinculum runtime with the example plugin
# baked in. Build the .so first with `make docker-build` (which uses the
# matching vinculum-build image so the ABI lines up), then:
#
#	docker build -t my-vinculum-with-example .
#	docker run --rm -v "$PWD/examples":/conf my-vinculum-with-example
#
# The base image already pre-creates /plugins and passes
# `--plugin-path /plugins` in its default CMD, so dropping the .so in is
# all that is required.
#
# IMPORTANT: the base image tag MUST match the vinculum-build tag used to
# compile example.so.
FROM ghcr.io/tsarna/vinculum:0.36.0

COPY example.so /plugins/
