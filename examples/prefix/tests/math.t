/ math.t - Tests auto-load src/math.q via prefix substitution
/ Run: q qdust.q --root examples/prefix/ test examples/prefix/tests/math.t

q)square[5]
25

q)square[0]
0

q)cube[3]
27

q)mean[1 2 3 4 5]
3f
