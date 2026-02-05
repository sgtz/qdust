/ labels.q - Using /@fn: to label tests
/ Run: q qdust.q test labels.q
/ Run: q qdust.q --fn add test labels.q

/ Implicit label from function definition
add:{x+y}
/// add[1;2] -> 3
/// add[10;20] -> 30

mul:{x*y}
/// mul[3;4] -> 12

/ Explicit label
/@fn:add
/// add[0;0] -> 0

/ Free text labels
/@fn:edge cases
/// 0%0 -> 0n
/// 1%0 -> 0w

/ Reset to no label
/@fn:
/// 1=1 -> 1b
