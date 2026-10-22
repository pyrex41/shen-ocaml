(define native-typed-add { number --> number }
  X -> (+ X 2))

(define native-typed-call { number --> number }
  X -> (native-typed-add X))

(define native-typed-length { (list A) --> number }
  [] -> 0
  [X | Xs] -> (+ 1 (native-typed-length Xs)))

(define native-typed-even { number --> boolean }
  0 -> true
  N -> (native-typed-odd (- N 1)))

(define native-typed-odd { number --> boolean }
  0 -> false
  N -> (native-typed-even (- N 1)))

(define native-typed-effect { number --> number }
  X -> (simple-error "typed body was executed"))

(define native-typed-zero { --> number }
  -> 42)

(define native-typed-lambda { number --> (number --> number) }
  X -> (/. Y Y))
