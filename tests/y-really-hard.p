cnf(a, axiom, '@'('@'(k, X), Y) = X).
cnf(a, axiom, '@'('@'('@'(s, X), Y), Z) = '@'('@'(X, Z), '@'(Y, Z))).
cnf(a, axiom, '@'(X, a(X)) != '@'(a(X), '@'(X, a(X)))).