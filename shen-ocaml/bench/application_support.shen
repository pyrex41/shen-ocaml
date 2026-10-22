\* Shared program-level benchmark helpers. Loaded untyped on both ports. *\
(define scoreboard.check
  Name Actual Expected -> true where (= Actual Expected)
  Name _ _ -> (simple-error Name))

(define scoreboard.repeat
  0 _ _ _ -> true
  N F Expected Name ->
    (do (scoreboard.check Name (thaw F) Expected)
        (scoreboard.repeat (- N 1) F Expected Name)))

(define scoreboard.measure
  Name Phase N F Expected ->
    (let Wall (get-time unix) CPU (get-time run)
         _ (scoreboard.repeat N F Expected Name)
         CPU (- (get-time run) CPU) Wall (- (get-time unix) Wall)
         Hush (value *hush*) _ (set *hush* false)
         _ (output "~%SCORE_RESULT ~A ~A ~A ~A ~A~%" Name Phase N CPU Wall)
      (set *hush* Hush)))

(define scoreboard.profile
  Deadline F Expected Name Count -> Count where (> (get-time unix) Deadline)
  Deadline F Expected Name Count ->
    (do (scoreboard.check Name (thaw F) Expected)
        (scoreboard.profile Deadline F Expected Name (+ Count 1))))

(define scoreboard.range
  0 Acc -> Acc
  N Acc -> (scoreboard.range (- N 1) [N | Acc]))

(define scoreboard.fold
  _ Acc [] -> Acc
  F Acc [X | XS] -> (scoreboard.fold F (F Acc X) XS))

(define scoreboard.list-pipeline
  N -> (scoreboard.fold (/. A X (+ A X)) 0
          (map (/. X (+ X 1)) (scoreboard.range N []))))

(define scoreboard.dict-fill
  0 D -> D
  N D -> (do (shen.dict-> D (cn "key-" (str N)) N)
             (scoreboard.dict-fill (- N 1) D)))

(define scoreboard.dict-sum
  0 _ Acc -> Acc
  N D Acc -> (scoreboard.dict-sum (- N 1) D
                 (+ Acc (shen.<-dict D (cn "key-" (str N))))))

(define scoreboard.dictionary
  N -> (let D (scoreboard.dict-fill N (shen.dict 257))
         (scoreboard.dict-sum N D 0)))
