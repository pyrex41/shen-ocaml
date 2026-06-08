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
