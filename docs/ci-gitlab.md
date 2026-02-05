# Qdust GitLab CI Integration

This guide shows you how to integrate qdust into your GitLab CI/CD pipeline for automated testing.

## Quick Start

Add this to your `.gitlab-ci.yml`:

```yaml
qdust-test:
  stage: test
  script:
    - q qdust.q test .
  allow_failure: false
```

That's it! Tests run on every push. Pipeline fails if tests fail.

## Recommended Setup

Here's a more complete configuration:

```yaml
stages:
  - test

qdust-test:
  stage: test
  script:
    # Fail fast if stale artifacts exist
    - q qdust.q check .

    # Run all tests
    - q qdust.q test .

  artifacts:
    when: on_failure
    paths:
      - "**/*.corrected"
      - "**/*.failed"
    expire_in: 1 week
```

### What This Does

1. **Pre-flight check**: `qdust check` fails if `.corrected` or `.failed` files exist. This catches uncommitted test changes.

2. **Run tests**: `qdust test .` runs all `.q` and `.t` files recursively.

3. **Artifacts on failure**: If tests fail, GitLab keeps the `.corrected` files so you can download and review them.

## JUnit Integration

GitLab can display test results in merge requests using JUnit XML:

```yaml
qdust-test:
  stage: test
  script:
    - q qdust.q check .
    - q qdust.q --junit test . > results.xml || true
    - q qdust.q test .  # Exit with proper code

  artifacts:
    when: always
    reports:
      junit: results.xml
    paths:
      - "**/*.corrected"
      - "**/*.failed"
    expire_in: 1 week
```

Now test failures appear as annotations in your MR diff!

## Blocking Conditions

Your pipeline should block (fail) when:

| Condition | Why | How to Fix |
|-----------|-----|------------|
| `qdust check` fails | Uncommitted test changes | Promote or revert |
| `qdust test` fails | Code doesn't match expectations | Fix code or promote |
| `.corrected` generated | New failures detected | Fix code or promote |

## Auto-Promote Workflow

For a stricter workflow, auto-promote and check for changes:

```yaml
qdust-test:
  stage: test
  script:
    - q qdust.q check .
    - q qdust.q --auto-merge-new test .
    - git diff --exit-code  # Fail if files changed
```

This fails if:
- Any `.corrected`/`.failed` files existed before tests
- Any tests failed (modified/error)
- Any new tests were auto-promoted (uncommitted changes)

Use this when you want to ensure all test changes are committed.

## Separate Stages

For larger projects, separate check and test stages:

```yaml
stages:
  - preflight
  - test

qdust-check:
  stage: preflight
  script:
    - q qdust.q check .
  allow_failure: false

qdust-test:
  stage: test
  needs: [qdust-check]
  script:
    - q qdust.q --junit test . > results.xml
  artifacts:
    when: always
    reports:
      junit: results.xml
    paths:
      - "**/*.corrected"
    expire_in: 1 week
```

## Directory Structure

Recommended project layout:

```
my-project/
├── src/
│   ├── lib.q
│   └── utils.q
├── tests/
│   ├── test_lib.q
│   ├── test_utils.q
│   └── integration.q
├── .gitlab-ci.yml
└── .gitignore
```

Test specific directories:

```yaml
qdust-test:
  script:
    - q qdust.q test tests/
```

## .gitignore

Always ignore qdust artifacts:

```gitignore
# Qdust test artifacts
*.corrected
*.failed
```

Or use qdust to add them:

```bash
q qdust.q gitignore
```

## Environment Detection

Qdust automatically detects CI environments:

- When `CI=true` is set (GitLab sets this automatically)
- Forces console diff mode (no IDE)
- Disables interactive features

You don't need to configure anything special.

## Troubleshooting

### Tests Pass Locally But Fail in CI

1. **Missing dependencies**: Ensure all required files are committed
2. **Path issues**: Use relative paths in test files
3. **Environment differences**: Check Q version, OS differences

### .corrected Files Keep Appearing

1. Run `qdust check` locally before pushing
2. Either promote the changes or fix the tests
3. Commit the result

### Pipeline Always Fails

Check if:
1. `.corrected` files are committed (remove them!)
2. Tests actually fail (run locally to debug)
3. `qdust check` is failing (stale artifacts)

### Viewing Failed Test Details

1. Download artifacts from failed pipeline
2. Look at `.corrected` files
3. Compare with original files
4. Use `git diff file.q file.q.corrected`

## Advanced: Parallel Testing

For large test suites, run in parallel:

```yaml
qdust-test:
  stage: test
  parallel:
    matrix:
      - TEST_DIR: [tests/unit, tests/integration, tests/e2e]
  script:
    - q qdust.q test $TEST_DIR
```

## Advanced: Scheduled Full Test

Run comprehensive tests on schedule:

```yaml
qdust-full-test:
  stage: test
  script:
    - q qdust.q test .
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

## Complete Example

Here's a production-ready `.gitlab-ci.yml`:

```yaml
stages:
  - preflight
  - test
  - report

variables:
  # Ensure clean environment
  GIT_CLEAN_FLAGS: -ffdx

qdust-check:
  stage: preflight
  script:
    - q qdust.q check .
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

qdust-unit-tests:
  stage: test
  needs: [qdust-check]
  script:
    - q qdust.q --junit test tests/unit/ > unit-results.xml
  artifacts:
    when: always
    reports:
      junit: unit-results.xml
    paths:
      - "tests/unit/**/*.corrected"
    expire_in: 1 week

qdust-integration-tests:
  stage: test
  needs: [qdust-check]
  script:
    - q qdust.q --junit test tests/integration/ > integration-results.xml
  artifacts:
    when: always
    reports:
      junit: integration-results.xml
    paths:
      - "tests/integration/**/*.corrected"
    expire_in: 1 week

test-summary:
  stage: report
  needs: [qdust-unit-tests, qdust-integration-tests]
  script:
    - echo "All tests completed"
  when: always
```

## See Also

- [Tutorial](tutorial.md) - Getting started with qdust
- [Advanced Guide](advanced.md) - All options and features
- [GitLab CI/CD Documentation](https://docs.gitlab.com/ee/ci/)
