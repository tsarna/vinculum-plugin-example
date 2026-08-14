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
2. **A function `example::greet(name)`** — returns `"<greeting>, <name>!"`,
   where `<greeting>` is the block's `greeting` attribute (default `"Hello"`).
   Vinculum namespaces its own function families this way (`log::info`,
   `http::get`, `time::add`), and plugins should too — HCL parses `a::b(x)`
   natively and resolves it as a single flat map key, so it costs nothing
   beyond spelling the registry key that way.

```hcl
# boot.vinit
plugin "example" {
  greeting = "Hi"
  answer   = 42
}
```

```hcl
# example.vcl
assert "greet" { condition = example::greet("world") == "Hi, world!" }
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
| `renovate.json` | Renovate config; bumps the vinculum go.mod dep and Docker base image together (CI verifies each bump). |
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
        return map[string]function.Function{"example::greet": /* ... */}
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
matching `vinculum-build` image using its bundled `vinculum-plugin-build`
wrapper, which enforces the toolchain and build flags and fails fast if any
shared dependency drifts from the release:

```sh
make docker-build VINCULUM_VERSION=0.45.0
```

> Plugin support in the container images requires **vinculum ≥ 0.37.1**
> (earlier images were built without cgo and cannot build or load plugins).
> Your `go.mod` must `require github.com/tsarna/vinculum` at the **same**
> version as `VINCULUM_VERSION`.

Then bake the `.so` into a runtime image (see [`Dockerfile`](Dockerfile)) whose
tag matches the build image:

```dockerfile
FROM ghcr.io/tsarna/vinculum:0.45.0
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
| `RegisterConditionalTriggerType` | a `trigger "type"` whose availability depends on config state (e.g. a feature flag), resolved per `Build()` |
| `RegisterConditionSubtype` | `condition "subtype"` blocks |
| `RegisterWireFormatType` | `wire_format "type"` blocks |
| `RegisterEditorType` | `editor "type"` blocks |
| `RegisterFunctyType` | a named type usable in [functy](https://github.com/tsarna/functy) (`.cty`) annotations — a capsule type, or a rich object's type when its attribute set is fixed |
| `RegisterFunctyOpenType` | the open, predicate-backed form of the above, for a type with no single fixed `cty.Type` (attributes vary per instance, or interface dispatch spans several capsules) |
| `RegisterFunctyExterns` | a `//functy:extern` source declaring the *real* signatures of the functions you contribute, so `help()` and editor tooling show them correctly |

The last three arrived with the functy integration in vinculum 0.43.0. They
matter if your plugin contributes its own types or functions: cty can only make
a *trailing* parameter optional, so a function taking an optional leading `ctx`
has to fake it with a variadic and reflects uselessly as `f(thing, ...args)` —
an extern states what it actually accepts. Note that functy checks extern names
for collisions (two plugins declaring the same name is an error), which the
function-plugin registry does not.

Plugins **cannot** add entirely new top-level `.vcl` block types — the set of
recognized block types is fixed by the host binary.

### Describing a block type you contribute

The seven registration functions that add a *block type* — server, client,
trigger, conditional trigger, condition subtype, wire format, and editor — take
optional `RegisterOption` arguments. Pass `config.WithSchema` so
[`vinculum schema`](https://github.com/tsarna/vinculum/blob/main/doc/schema.md)
can describe your block the same way it describes the built-in ones:

```go
config.RegisterClientType("acme", process, config.WithSchema(config.TypeSchema{
    Sample:  &acmeClientDefinition{},   // your gohcl decode struct
    Summary: "Connects to an Acme widget broker.",
    Attrs: map[string]config.AttrMeta{
        "url":     {Summary: "Broker URL.", Hint: config.HintURL},
        "timeout": {Summary: "Request deadline.", Hint: config.HintDuration},
    },
}))
```

`Sample` is the decode struct itself, so attributes, their required-ness, and
nested sub-blocks are reflected rather than restated — you write only the prose
and hints, and they are checked against the reflected structure.

`vinculum schema` describes a stock binary by default; pass `--plugin-path` and
the config paths that declare your plugin to include its types:

```sh
vinculum schema --plugin-path ./plugins ./configs/
```

`RegisterConditionalTriggerType` takes `config.WithVariantSchemas` instead — its
factory cannot run without a `*Config`, so the type names have to be named
explicitly.

This example registers a function and an ambient value rather than a block
type, so it has nothing to pass `WithSchema` to. Arrived in vinculum 0.45.0.

## Further reading

- Vinculum plugin documentation: [`doc/plugins.md`](https://github.com/tsarna/vinculum/blob/main/doc/plugins.md)
- `.vinit` bootstrap files: [`doc/vinit.md`](https://github.com/tsarna/vinculum/blob/main/doc/vinit.md)
- Container / build images: [`doc/container.md`](https://github.com/tsarna/vinculum/blob/main/doc/container.md)
