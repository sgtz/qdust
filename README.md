# qdust

Expect test runner for KDB+/Q.

With traditional testing you write assertions by hand and maintain expected values manually. With expect testing you just write expressions — qdust runs them, captures the output, and shows you a diff. If it looks right, `promote` and move on. The test file is the expected output. No boilerplate, no manual upkeep. Inspired by [The Joy of Expect Tests](https://blog.janestreet.com/the-joy-of-expect-tests/).

## Quick Start

**REPL tests** in `.t` files - paste from console:

```q
q)1+1
2
q)til 5
0 1 2 3 4
```

**Inline tests** in `.q` files:

```q
/// 1+1 -> 2
/// reverse 1 2 3 -> 3 2 1
```

Run: `q qdust.q test file.q`

This evaluates expressions and writes a `.corrected` file with the actual output. If expected results don't exist yet, they're captured; if they do, mismatches are shown as diffs. Review with your diff tool and accept some, all, or none of the changes as the new expected output. Most IDEs handle external file changes gracefully, so this fits naturally into an existing workflow.

## Statements vs Tests

Trailing semicolon = no output expected:

```q
q)t:([] a:1 2 3);
q)count t
3
```

## Commands

```bash
q qdust.q test                  # run all tests in project (.qd/.git root)
q qdust.q test -filter math     # filter project files by name
q qdust.q test dir/             # run tests in directory
q qdust.q test file.q           # run tests in single file
q qdust.q promote dir/          # accept all .corrected files
q qdust.q promote file.q        # accept single file
q qdust.q check                 # fail if .corrected files exist (CI)
```

## Loading (.t files)

**Paired files:** `code.t` auto-loads `code.q`

**Explicit:** `/ @load lib.q`

**Prefix substitution:** `tests/foo.t` resolves `src/foo.q`

## Options

```
-filter <pat>      Filter project files by name/glob
-fn <name>         Run only tests for named function
-init <file>       Load init file
-debug             Debug mode (single file, errors break to q))
-noipc             Disable IPC worker mode (use subprocess instead)
-timeout <secs>    Per-expression timeout in seconds (default 5)
-json              JSON output
-junit             JUnit XML output
-errors-only       Show only failures
```

## Environment

```bash
QDUST_INIT      Init file path
QDUST_DIFF      Diff tool (e.g. "code --diff")
QDUST_TIMEOUT   Per-expression timeout in seconds (IPC mode)
```

## More

- [Editor Setup](docs/editor-setup.md) - configure `.t` syntax highlighting for VS Code, IntelliJ, Vim, Emacs
- [Advanced](docs/advanced.md) - directives (`/@fn:`, `/@ci:`), labels for grouping tests, CI integration with JUnit output

## License

MIT
