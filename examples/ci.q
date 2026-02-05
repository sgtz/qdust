/ ci.q - CI directives
/ Run: q qdust.q test ci.q

/ Default: required (must pass)
/// 1+1 -> 2

/@ci:required
/// 2+2 -> 4

/ Optional: failure is warning only
/@ci:optional
/// sum til 1000 -> 499500

/ Skip: not run in CI
/@ci:skip
/// .z.o -> `l64
