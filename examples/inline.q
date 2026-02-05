/ inline.q - Inline tests with -> in .q files
/ Run: q qdust.q test inline.q

/// 1+1 -> 2
/// 2*3 -> 6
/// til 5 -> 0 1 2 3 4
/// reverse 1 2 3 -> 3 2 1
/// count "hello" -> 5

/ REPL inline also works
/// q)10+10 -> 20
/// q)sum 1 2 3 -> 6

/ Console format (output underneath)
/// q)til 3
/// 0 1 2
