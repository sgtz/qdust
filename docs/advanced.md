# Advanced Features

## Directives

Directives are paste-safe Q comments that control test behavior:

```q
/@fn:label              Link following tests to label
/@fn:                   Reset (no label)
/@ci:required           Tests must pass (default)
/@ci:optional           Failures are warnings
/@ci:skip               Skip tests
```

## Labels

Labels group tests and can be any text - function names, namespaces, or descriptions:

```q
/@fn:add
/// add[1;2] -> 3

/@fn:.utils.parse
/// parse["123"] -> 123

/@fn:edge cases
/// 0%0 -> 0n
```

### Implicit Labels

In `.q` files, function definitions set implicit context:

```q
add:{x+y}
/// add[1;2] -> 3      / linked to 'add' implicitly

mul:{x*y}
/// mul[2;3] -> 6      / linked to 'mul' implicitly
```

### Filtering by Label

Run only tests with a specific label:

```bash
q qdust.q --fn add test file.q
q qdust.q --fn ".utils.parse" test file.q
q qdust.q --fn "edge cases" test file.q
```

## CI Tags

Control test behavior in CI environments:

```q
/@ci:required          / must pass (default)
/@ci:optional          / warning only
/@ci:skip              / don't run
```

### JUnit Output

For CI integration, use JUnit XML output:

```bash
q qdust.q --junit test file.q > results.xml
```

This format is recognized by:
- GitHub Actions
- GitLab CI
- Gitea Actions
- Jenkins
- Most CI systems

### Exit Codes

- `0` - all tests passed
- `1` - one or more tests failed

## Custom Loader

Override the default file loader for custom dependency management:

```q
/ qdust-init.q
.qd.customloader:{[file]
  / Your custom loading logic
  .myloader.load file}
```

Set via environment or command line:

```bash
export QDUST_INIT=qdust-init.q
q qdust.q test file.t

# or
q qdust.q --init qdust-init.q test file.t
```
