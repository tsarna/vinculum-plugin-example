// Exercise the contributions made by the example plugin. `vinculum check`
// evaluates these assert blocks, so a successful check proves the plugin
// loaded and both the ambient `example.*` value and the `example_greet`
// function are available.

// The ambient provider surfaces each plugin-block attribute.
assert "ambient_greeting" {
  condition = example.greeting == "Hi"
}

assert "ambient_answer" {
  condition = example.answer == 42
}

// The function combines the block's greeting with its argument.
assert "function_greet" {
  condition = example_greet("world") == "Hi, world!"
}
