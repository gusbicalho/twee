cnf(plus_comm, axiom, '+'(X, Y) = '+'(Y, X)).
cnf(plus_assoc, axiom, '+'(X, '+'(Y, Z)) = '+'('+'(X, Y), Z)).
cnf(plus_zero, axiom, '+'('0', X) = X).
cnf(plus_inv, axiom, '+'(X, '-'(X)) = '0').
cnf(times_ssoc, axiom, '*'(X, '*'(Y, Z)) = '*'('*'(X, Y), Z)).
cnf(distrib, axiom, '*'(X, '+'(Y, Z)) = '+'('*'(X, Y), '*'(X, Z))).
cnf(distrib, axiom, '*'('+'(X, Y), Z) = '+'('*'(X, Z), '*'(Y, Z))).
cnf(power_five, axiom, X = '*'(X, '*'(X, '*'(X, '*'(X, X))))).
cnf(conjecture, negated_conjecture, '*'(a, b) != '*'(b, a)).
cnf(lhs, axiom, lhs = '*'(a, b)).
cnf(rhs, axiom, rhs = '*'(b, a)).