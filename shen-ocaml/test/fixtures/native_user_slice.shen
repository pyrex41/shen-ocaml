\\ Restricted native-user compiler fixture (no top-level execution).
(define native-slice-sum
  0 Acc -> Acc
  N Acc -> (native-slice-sum (- N 1) (+ Acc N)))

(define native-slice-length
  [] -> 0
  [X | XS] -> (+ 1 (native-slice-length XS)))

(define native-slice-increment X -> (+ X 1))
(define native-slice-caller X -> (native-slice-increment X))
(define native-slice-increment X -> (+ X 2))
(define native-slice-lambda X -> ((/. Y (+ X Y)) 2))
(define native-slice-effect X -> (set native-slice-marker X))
