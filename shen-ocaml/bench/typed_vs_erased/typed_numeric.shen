\\ Phase C benchmark/fixture: single-clause numeric functions with { number ...}
\\ signatures. Compiled two ways — signature consumed (unboxed int) vs ignored
\\ (uniform tagged value). All type-check under (tc +); that is the soundness
\\ warrant for emitting a fast path.

\\ Loop-carried LCG fold: Acc depends multiplicatively on the previous Acc and
\\ wraps on 63-bit overflow, so it cannot be reduced to a closed form.
(define lcg
  { number --> number --> number }
  Acc N -> (if (= N 0) Acc (lcg (+ (* Acc 1664525) N) (- N 1))))

\\ Simple accumulator (triangular). Kept as an honest "easy" case.
(define sumto
  { number --> number --> number }
  Acc N -> (if (= N 0) Acc (sumto (+ Acc N) (- N 1))))

\\ Tree recursion (non-tail), exercises mutual/self specialized calls.
(define fibo
  { number --> number }
  N -> (if (< N 2) N (+ (fibo (- N 1)) (fibo (- N 2)))))

\\ Calls another specialized function (sumto): exercises direct specialized->
\\ specialized calls and the redefinition-invalidation invariant.
(define usesum
  { number --> number }
  N -> (* 2 (sumto 0 N)))

\\ number-monomorphic signature but the body leaves the int subset (cons/hd), so
\\ it must fall back to the uniform entry — no fast path. Tests silent fallback.
(define usescons
  { number --> number }
  N -> (hd (cons N N)))

\\ Works in BOTH the int and float subsets: gets two unboxed entries; the wrapper
\\ picks by argument type. Tests int/float dual dispatch.
(define square
  { number --> number }
  X -> (* X X))

\\ Float-only: the 0.5 literal is rejected by the int subset, so only a float fast
\\ path is emitted; integer args fall back to uniform (correct contagion).
(define halfsq
  { number --> number }
  X -> (* (* X X) 0.5))

\\ Multi-clause with an INT literal base case -> lowered to an if-chain. INT-only
\\ (the int literal 0 is structural; the interpreter does not terminate on float
\\ args, so it is correctly NOT float-specialized).
(define facto
  { number --> number }
  0 -> 1
  N -> (* N (facto (- N 1))))

\\ Float-only loop-carried fold (float literals 0.0/1.0 -> the interpreter compares
\\ float-to-float and terminates; no int literals so the int subset rejects it).
(define fsum
  { number --> number --> number }
  Acc N -> (if (= N 0.0) Acc (fsum (+ Acc N) (- N 1.0))))
