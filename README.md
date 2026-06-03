# Vinculum Plugin Example

A small, runnable example of a [Vinculum](https://github.com/tsarna/vinculum)
plugin — plus a project skeleton you can copy, and a step-by-step tutorial for
writing your own.

A Vinculum plugin is a Go shared object (`.so`, built with
`-buildmode=plugin`) that Vinculum loads at startup. Plugins extend Vinculum
using the same registration mechanisms the in-tree subsystems use: they can
contribute functions, transforms, ambient variables, server/client types,
trigger types, condition subtypes, wire formats, and editor types — without
forking and rebuilding the binary.

This example contributes two things:

1. **An ambient provider `example.*`** — every attribute of the
   `plugin "example" { ... }` block is surfaced as a top-level VCL value.
   With the block below, `example.greeting == "Hi"` and `example.answer == 42`.
2. **A function `example_greet(name)`** — returns `"<greeting>, <name>!"`,
   where `<greeting>` is the block's `greeting` attribute (default `"Hello"`).

```hcl
# boot.vinit
plugin "example" {
  greeting = "Hi"
  answer   = 42
}
```

```hcl
# example.vcl
assert "greet" { condition = example_greet("world") == "Hi, world!" }
assert "ambient" { condition = example.answer == 42 }
```

## Repository layout

| Path | Purpose |
|---|---|
| `plugin.go` | The plugin. A `package main` with the `VinculumPluginInit` entry point. |
| `examples/boot.vinit` | Declares `plugin "example"`. `.vinit` files are processed before any `.vcl`. |
| `examples/example.vcl` | `assert` blocks that exercise the plugin's contributions. |
| `Makefile` | `build`, `docker-build`, `smoke`, `clean` targets. |
| `Dockerfile` | Example deployment image (released runtime + the `.so`). |
| `go.work` | **Gitignored**, local-dev only — links `../vinculum` for ABI-matched local builds. |

## Anatomy of a plugin

A plugin is a `main` package that exports exactly one symbol:

```go
func VinculumPluginInit(ctx *config.PluginContext) hcl.Diagnostics
```

Vinculum opens the `.so`, looks up `VinculumPluginInit` by name, and calls it
once at startup — before any `.vcl` is parsed — so the plugin's contributions
are visible everywhere in the configuration. Returning error diagnostics aborts
startup.

`ctx` ([`config.PluginContext`](https://github.com/tsarna/vinculum/blob/main/config/plugin_common.go))
provides:

- **`ctx.Block`** — the `plugin "<label>" { ... }` block. Decode `ctx.Block.Body`
  with `JustAttributes()`, `gohcl`, or the raw HCL API to read your own config.
  (`disabled` is consumed by Vinculum before you're called but is still present
  in the body — skip it when iterating attributes.)
- **`ctx.EvalContext`** — the minimal `.vinit` eval context: `env.*` and the cty
  standard library. No `const`, no user functions, no other plugins.
- **`ctx.Logger`** — a `*zap.Logger` pre-bound with `plugin=<label>` (may be nil).

Inside `VinculumPluginInit` you call the relevant `config.Register*` functions.
See [`plugin.go`](plugin.go) for the fully-commented implementation; the shape is:

```go
func VinculumPluginInit(ctx *config.PluginContext) hcl.Diagnostics {
    attrs, diags := ctx.Block.Body.JustAttributes()
    // ... evaluate attrs against ctx.EvalContext, skipping "disabled" ...

    config.RegisterAmbientProvider("example", func(_ *config.Config) cty.Value {
        return exampleObj // surfaced as `example.*` in VCL
    })
    config.RegisterFunctionPlugin("example", func(_ *config.Config) map[string]function.Function {
        return map[string]function.Function{"example_greet": /* ... */}
    })
    return diags
}
```

## Building

### Local development (this repo's `make build` / `make smoke`)

Go plugins are **extremely** ABI-sensitive: the `.so` and the host `vinculum`
binary must be compiled from the *identical* source of every shared package.
During development your `../vinculum` checkout is usually ahead of the last
released tag, so this repo ships a **gitignored** `go.work` that points both
builds at the local source:

```
go 1.26.0
use (
    .
    ../vinculum
)
```

With that in place:

```sh
make build    # -> example.so, built against ../vinculum
make smoke    # build a host binary + the plugin and run `vinculum check`
```

`make smoke` is the end-to-end check: it builds a `vinculum` binary and the
`.so` from the same local source, then runs
`vinculum check --plugin-path … examples/`. A passing check proves the plugin
loaded and its contributions resolved.

### Deployment (`make docker-build`)

For a real deployment, build against the *released* vinculum module inside the
matching `vinculum-build` image, which pins the Go toolchain, dependency
versions, and build flags to the values used by that Vinculum release:

```sh
make docker-build VINCULUM_VERSION=0.37.0
```

Then bake the `.so` into a runtime image (see [`Dockerfile`](Dockerfile)) whose
tag matches the build image:

```dockerfile
FROM ghcr.io/tsarna/vinculum:0.37.0
COPY example.so /plugins/
```

The runtime image pre-creates `/plugins` and passes `--plugin-path /plugins` in
its default `CMD`, so dropping the `.so` in is enough. **The runtime tag, the
build-image tag, and the `github.com/tsarna/vinculum` version in `go.mod` must
all match.**

## ABI rules (read this before you debug a load failure)

A `plugin.Open … different version of package X` error almost always means an
ABI mismatch. The plugin and host must agree on:

- the **Go toolchain version**, down to the patch release;
- the **version of every shared module** (especially `github.com/tsarna/vinculum`
  and everything it transitively imports);
- **build flags** (`-trimpath`, build tags); and
- **GOOS / GOARCH**.

**cgo is required, on both sides.** `-buildmode=plugin` always forces external
linking (the Go toolchain requires it "even for programs that do not use cgo"),
so building a plugin with `CGO_ENABLED=0` fails outright:

```text
-buildmode=plugin requires external (cgo) linking, but cgo is not enabled
```

A statically linked, cgo-disabled host binary likewise cannot load any plugin.
So both the host `vinculum` binary and the plugin must be built with cgo enabled
(`CGO_ENABLED=1`, with a C toolchain available). On Linux/amd64 and Linux/arm64
cgo is enabled by default when a C compiler is present.

Building both the host and the plugin in the same environment — with the same
toolchain and cgo on — is what keeps all of these aligned. The local `go.work`
(dev) does this against `../vinculum`; CI does it on the runner (see
[`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

Plugin loading is only available on **Linux, macOS, and FreeBSD**. Production
deployments should target Linux; the macOS pairing is fragile across OS releases.

## Other extension points

This example uses two registration functions. A plugin may call any of these
from `VinculumPluginInit`:

| Function | Contributes |
|---|---|
| `RegisterFunctionPlugin` | VCL functions |
| `RegisterTransformPlugin` | transform-pipeline functions |
| `RegisterAmbientProvider` | top-level VCL values (like `example.*` here) |
| `RegisterServerType` | `server "type"` blocks |
| `RegisterClientType` | `client "type"` blocks |
| `RegisterTriggerType` | `trigger "type"` blocks |
| `RegisterConditionSubtype` | `condition "subtype"` blocks |
| `RegisterWireFormatType` | `wire_format "type"` blocks |
| `RegisterEditorType` | `editor "type"` blocks |

Plugins **cannot** add entirely new top-level `.vcl` block types — the set of
recognized block types is fixed by the host binary.

## Further reading

- Vinculum plugin documentation: [`doc/plugins.md`](https://github.com/tsarna/vinculum/blob/main/doc/plugins.md)
- `.vinit` bootstrap files: [`doc/vinit.md`](https://github.com/tsarna/vinculum/blob/main/doc/vinit.md)
- Container / build images: [`doc/container.md`](https://github.com/tsarna/vinculum/blob/main/doc/container.md)
