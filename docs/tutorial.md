# Getting Started with Qdust

Welcome! Qdust is a testing tool for Q/K that makes it easy to write, run, and maintain tests. If you've ever wished for a simple way to verify your Q code works correctly, you're in the right place.

## What is Qdust?

Qdust brings "expect testing" to Q/K. You write expressions and their expected output directly in your code, and qdust checks if they match. When they don't, it shows you exactly what changed and lets you update your expectations with a single command.

The workflow is simple:
1. **Test** - Run your tests
2. **Diff** - See what changed
3. **Promote** - Accept the changes

No more manually updating test files. No more "expected X but got Y" debugging sessions. Just write, test, and move on.

## Your First Test

Let's write a test. Create a file called `mytest.q`:

```q
/ mytest.q - My first qdust test

/// 1+1 -> 2
```

That's it! The `///` marks a test line, followed by an expression, then `->`, then the expected result.

Run it:

```bash
q qdust.q test mytest.q
```

You should see:

```
--- Sections ---
  [PASS] (default): 1/1

--- Summary ---
  File: mytest.q
  Passed: 1
  Failed: 0
  Total: 1
```

Your first test passes!

## Adding More Tests

Let's add a few more tests to `mytest.q`:

```q
/ mytest.q - My first qdust tests

/ # Arithmetic
/// 1+1 -> 2
/// 2*3 -> 6
/// 10%2 -> 5

/ # Lists
/// til 5 -> 0 1 2 3 4
/// reverse 1 2 3 -> 3 2 1
/// count "hello" -> 5
```

The `/ #` lines create **sections**. They organize your tests and appear in the output:

```
--- Sections ---
  [PASS] Arithmetic: 3/3
  [PASS] Lists: 3/3
```

## What Happens When a Test Fails?

Let's see what happens when expected doesn't match actual. Change one of your tests:

```q
/// 2*3 -> 7
```

Run the tests again:

```bash
q qdust.q test mytest.q
```

Now you'll see:

```
File "mytest.q", line 5, characters 0-0: (Arithmetic) [MODIFIED]
  Expression: 2*3
  Expected:   7
  Actual:     6

--- Summary ---
  Passed: 5
  Failed: 1
  Total: 6

Wrote mytest.q.corrected (use 'git diff' or 'qdust promote' to review)
```

Qdust shows you exactly what went wrong:
- Which file and line
- What expression was tested
- What you expected vs what you got

It also created `mytest.q.corrected` with the actual values filled in.

## The Promote Workflow

You have two choices when a test fails:

### Option 1: Fix Your Code
If the test caught a real bug, fix your code and run tests again.

### Option 2: Update Your Expectations
If the new output is correct (maybe you improved something), accept it:

```bash
q qdust.q promote mytest.q
```

This copies `mytest.q.corrected` over `mytest.q` and deletes the `.corrected` file.

Run tests again to confirm everything passes:

```bash
q qdust.q test mytest.q
```

## Testing Functions You Define

Tests can use functions defined in the same file:

```q
/ myfuncs.q - Testing my functions

/ Define functions first
double:{x*2}
add:{[a;b] a+b}

/ Then test them
/// double 5 -> 10
/// double 0 -> 0
/// add[2;3] -> 5
```

Qdust loads the file before running tests, so your functions are available.

## Multi-line Output

Some expressions produce output that spans multiple lines. Use **block format**:

```q
/// til 5
0
1
2
3
4
```

Just write the expression on the `///` line (no arrow), then put the expected output below.

Tables work the same way:

```q
/// ([] a:1 2 3; b:`x`y`z)
a b
---
1 x
2 y
3 z
```

## Adding New Tests

Don't know what the output will be? Leave the expected empty:

```q
/// someNewFunction[arg]
```

Or use a placeholder:

```q
/// someNewFunction[arg] -> *
```

When you run tests, qdust captures the output and marks it as `[NEW]`:

```
File "mytest.q", line 10: [NEW]
  Expression: someNewFunction[arg]
  Result:     42
```

Then promote to save the captured value.

## Running Multiple Files

Test a whole directory:

```bash
q qdust.q test tests/
```

Or use patterns:

```bash
q qdust.q test "test_*.q"
```

## Quick Reference

| Command | What it does |
|---------|--------------|
| `q qdust.q test file.q` | Run tests in one file |
| `q qdust.q test dir/` | Run tests in all files in directory |
| `q qdust.q promote file.q` | Accept .corrected as new expected |
| `q qdust.q check .` | Fail if .corrected/.failed files exist |

## Next Steps

You now know the basics! Check out:
- [Advanced Guide](advanced.md) - All options and features
- [GitLab CI Guide](ci-gitlab.md) - Set up automated testing
- [Examples](../examples/) - Working examples to explore

Happy testing!
