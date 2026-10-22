(define native-fast-sum
  0 Acc -> Acc
  N Acc -> (native-fast-sum (- N 1) (+ Acc N)))
