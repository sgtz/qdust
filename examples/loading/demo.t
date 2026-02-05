/ demo.t - Tests using @load to pull in dependencies
/ Run: q qdust.q --root examples/loading/ test examples/loading/demo.t

/ @load lib/utils.q

q)double[5]
10

q)double[0]
0

q)clamp[0;50;100]
50

q)clamp[0;-10;100]
0

q)clamp[0;200;100]
100
