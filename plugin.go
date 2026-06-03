// Command vinculum-plugin-example is a runnable example of a Vinculum
// plugin. It is built as a Go shared object:
//
//	go build -buildmode=plugin -trimpath -o example.so .
//
// and loaded by Vinculum when a `.vinit` file declares:
//
//	plugin "example" {
//	    greeting = "Hi"
//	    answer   = 42
//	}
//
// It demonstrates two of Vinculum's plugin extension points:
//
//  1. An ambient provider that surfaces every attribute of the plugin
//     block as a top-level VCL value under `example.*` (so the config
//     above yields `example.greeting == "Hi"` and `example.answer == 42`).
//
//  2. A function `example_greet(name)` that returns "<greeting>, <name>!",
//     where <greeting> comes from the block's `greeting` attribute
//     (defaulting to "Hello").
//
// See the README for a full walkthrough and the list of other Register*
// extension points a plugin may call.
package main

import (
	"github.com/hashicorp/hcl/v2"
	"github.com/tsarna/vinculum/config"
	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/function"
	"go.uber.org/zap"
)

// VinculumPluginInit is the entry point every Vinculum plugin must export
// under exactly this name and signature. Vinculum looks it up by symbol
// name after opening the .so, then calls it once during startup (before
// any .vcl is parsed). Returning error diagnostics aborts startup.
func VinculumPluginInit(ctx *config.PluginContext) hcl.Diagnostics {
	// Decode the plugin block body. We treat it as a flat set of
	// attributes; a plugin that needs nested blocks would decode the body
	// with gohcl or the raw HCL API instead of JustAttributes.
	attrs, diags := ctx.Block.Body.JustAttributes()
	if diags.HasErrors() {
		return diags
	}

	// Evaluate each attribute against the minimal .vinit eval context
	// (env.* + the cty standard library). The `disabled` attribute is
	// handled by Vinculum before we are called, but it is still present in
	// the body, so skip it.
	vals := map[string]cty.Value{}
	for name, attr := range attrs {
		if name == "disabled" {
			continue
		}
		v, evalDiags := attr.Expr.Value(ctx.EvalContext)
		diags = diags.Extend(evalDiags)
		if evalDiags.HasErrors() {
			continue
		}
		vals[name] = v
	}
	if diags.HasErrors() {
		return diags
	}

	exampleObj := cty.EmptyObjectVal
	if len(vals) > 0 {
		exampleObj = cty.ObjectVal(vals)
	}

	// Pull the greeting (if any) for use by the function below.
	greeting := "Hello"
	if g, ok := vals["greeting"]; ok && !g.IsNull() && g.Type() == cty.String {
		greeting = g.AsString()
	}

	if ctx.Logger != nil {
		ctx.Logger.Info("example plugin initialized",
			zap.Int("attributes", len(vals)),
			zap.String("greeting", greeting),
		)
	}

	// Contribute `example` to the global VCL eval context. The provider is
	// invoked once, during config Build(), after plugins have loaded.
	config.RegisterAmbientProvider("example", func(_ *config.Config) cty.Value {
		return exampleObj
	})

	// Contribute the example_greet(name) function.
	config.RegisterFunctionPlugin("example", func(_ *config.Config) map[string]function.Function {
		return map[string]function.Function{
			"example_greet": function.New(&function.Spec{
				Params: []function.Parameter{
					{Name: "name", Type: cty.String},
				},
				Type: function.StaticReturnType(cty.String),
				Impl: func(args []cty.Value, _ cty.Type) (cty.Value, error) {
					return cty.StringVal(greeting + ", " + args[0].AsString() + "!"), nil
				},
			}),
		}
	})

	return nil
}
