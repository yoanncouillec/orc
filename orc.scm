(module orc
   ;(include "misc.sch")
   (library pthread)
   (main main)
   (static
      (class pipe
         (mutex (default (make-mutex)))
         (condition (default (make-condition-variable)))
         (items (default (list))))
      (class variable
         name
         value
         status
         (mutex (default (make-mutex)))
         (condition (default (make-condition-variable))))
      (class environment
         variable
         next-environment)
      (class environment-empty::environment)
      (class closure
         environment
         variables
         body)))

(define print-mutex (make-mutex))

(define (print-x . l)
   (let ((ret #f))
      (mutex-lock! print-mutex)
      (let loop ((l l))
         (if (pair? l)
             (begin
                (display (car l))
                (loop (cdr l)))
             (set! ret (print))))
      (mutex-unlock! print-mutex)
      ret))

(define env-empty (instantiate::environment-empty
                     (variable 'none)
                     (next-environment 'none)))

(define-generic (environment-lookup env::environment x)
;   (print-x "\nenv-lookup, x = " x );", env = " env)
   (if (not (isa? env environment-empty))
       (let ((variable::variable env.variable))
          ;(print-x "TEST === x = " x " ET  var = " env.variable)
          (if (equal? variable.name x)
              (variable-get variable)
              (environment-lookup env.next-environment x)))
       (error "environment-lookup" "binding not found" x)))

(define-generic (environment-update env::environment x v)
   (if (not (equal? env class-nil))
       (let ((variable::variable env.variable))
          (if (equal? variable.name x)
              (begin
                 (variable-set variable v)
                 env)
              (environment-update env.next-environment x v)))
       (error "environment-update" "binding not found" x)))

(define-generic (environment-add env::environment x v)
;   (print-x "env-add, x = " x ", v = " v)
   (instantiate::environment
      (variable
         (instantiate::variable
            (name x)
            (value v)
            (status 'ready)))
      (next-environment env)))

(define-generic (environment-add-no-value env::environment x)
   (instantiate::environment
      (variable
         (instantiate::variable
            (name x)
            (value 'no-value)
            (status 'wait)))
      (next-environment env)))

(define-generic (variable-get variable::variable)
   (let ((return #f))
      (mutex-lock! variable.mutex)
      (if (equal? variable.status 'wait)
          (condition-variable-wait! variable.condition variable.mutex))
      (set! return variable.value)
      (mutex-unlock! variable.mutex)
      return))

(define-generic (variable-set variable::variable v)
   (mutex-lock! variable.mutex)
   (set! variable.value v)
   (set! variable.status 'ready)
   (condition-variable-broadcast! variable.condition)
   (mutex-unlock! variable.mutex))


(define-generic (pipe-get c::pipe)
   (mutex-lock! c.mutex)
   (let ((ret #f))
      (if (not (pair? c.items))
          (condition-variable-wait! c.condition c.mutex))
      (set! ret (car (reverse c.items)))
      (set! c.items (reverse (cdr (reverse c.items))))
      (mutex-unlock! c.mutex)
      ret))

(define-generic (pipe-put c::pipe item)
   (mutex-lock! c.mutex)
   (set! c.items (cons item c.items))
   (condition-variable-signal! c.condition)
   (mutex-unlock! c.mutex))

(define (eval->> e1 x e2 cout1 env)
;   (print-x "eval->>, e1 = " e1 ", e2 = " e2)
   (let ((cout2 (instantiate::pipe)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc e1 cout2 env)))))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (let loop ((v (pipe-get cout2)))
                     (if (not (equal? v 'stop))
                         (begin
                            (thread-start!
                               (instantiate::pthread
                                  (body
                                     (lambda ()
                                        (eval-orc
                                           e2
                                           cout1
                                           (environment-add env x v))))))
                            (loop (pipe-get cout2)))))))))))

(define (eval-// e1 e2 cout1 env)
;   (print-x "eval-//, e1 = " e1 ", e2 = " e2)
   (thread-start!
      (instantiate::pthread
         (body
            (lambda () (eval-orc e1 cout1 env)))))
   (thread-start!
      (instantiate::pthread
         (body
            (lambda () (eval-orc e2 cout1 env))))))

(define (eval-<< e1 x e2 cout1 env1)
;   (print-x "eval-<<, e1=" e1 ", e2=" e2)
;   (let ((mutex (make-mutex))
;         (condition (make-condition-variable)))
   (let ((cout2 (instantiate::pipe))
         (env2 (environment-add-no-value env1 x)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc e2 cout2 env1)
                  (environment-update env2 x (pipe-get cout2))))))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc e1 cout1 env2)))))))

(define (eval-val x expr body cout env)
   (let ((cout1 (instantiate::pipe))
         (env1 (environment-add-no-value env x)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc expr cout1 env)
                  (environment-update env1 x (pipe-get cout1))))))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc body cout env1)))))))

(define (eval-lambda vars body cout env)
;   (print-x "eval-lambda, x = " x ", body = " body)
   (let ((closure
            (instantiate::closure
               (environment env)
               (variables vars)
               (body body))))
      (pipe-put cout closure)))

(define (eval-application proc arguments cout env)
;   (print-x "eval-application, proc = " proc ", arguments = " arguments)
   (let loop ((pipes (list))
              (args arguments))
      (if (pair? args)
          (let ((pipe (instantiate::pipe))
                (arg (car args)))
             (thread-start!
                (instantiate::pthread
                   (body
                      (lambda ()
                         (eval-orc arg pipe env)))))
             (loop
                (cons pipe pipes)
                (cdr args)))
          (let ((cout1 (instantiate::pipe)))
             (thread-start!
                (instantiate::pthread
                   (body
                      (lambda ()
                         (eval-orc proc cout1 env)
                         (let ((closure::closure (pipe-get cout1)))
                            (let loop ((vars closure.variables)
                                       (pipes pipes))
                               (if (pair? vars)
                                   (let ((var (car vars))
                                         (pipe (car pipes)))
                                      (set! env (environment-add-no-value env var))
                                      (thread-start!
                                         (instantiate::pthread
                                            (body
                                               (lambda ()
                                                  (environment-update
                                                     env var (pipe-get pipe))))))
                                      (loop
                                         (cdr vars)
                                         (cdr pipes)))))
                            (eval-orc closure.body cout env))))))))))

(define (eval-site-call site arguments cout env)
   (let loop ((pipes (list))
              (args arguments))
      (if (pair? args)
          (let ((pipe (instantiate::pipe))
                (arg (car args)))
             (thread-start!
                (instantiate::pthread
                   (body
                      (lambda ()
                         (eval-orc arg pipe env)))))
             (loop
                (cons pipe pipes)
                (cdr args)))
          (let ((cout1 (instantiate::pipe)))
             (eval-orc site cout1 env)
             (let ((site::closure (pipe-get cout1)))
                (let loop ((env1 env)
                           (pipes pipes)
                           (variables (reverse site.variables)))
                   (if (pair? pipes)
                       (loop
                          (environment-add
                             env1 (car variables) (pipe-get (car pipes)))
                          (cdr pipes)
                          (cdr variables))
                       (let ((cout2 (instantiate::pipe)))
                          (eval-orc site.body cout2 env1)
                          (pipe-put cout (pipe-get cout2))))))))))

;(define (eval-application proc args cout env)
;   (print-x "eval-application, e1=" e1 ", e2=" e2)
;   (let ((cout1 (instantiate::pipe))
;         (cout2 (instantiate::pipe)))
;      (thread-start!
;         (instantiate::pthread
;            (body
;               (lambda ()
;                  (eval-orc e1 cout1 env)))))
;      (thread-start!
;         (instantiate::pthread
;            (body
;               (lambda ()
;                  (eval-orc e2 cout2 env)))))
;      (let ((closure::closure (pipe-get cout1))
;            (v2 (pipe-get cout2)))
;         (eval-orc
;            closure.body
;            cout
;            (environment-add closure.environment closure.variable v2)))))

(define (eval-symbol symb cout env)
;   (print-x "eval-symbol, " symb); ", env = " env)
   (if (not (equal? symb 'stop))
       (pipe-put cout
          (match-case symb
             (signal 'signal)
             (else
              (environment-lookup env symb))))))

(define (eval-binary op e1 e2 cout env)
   (let ((cout1 (instantiate::pipe))
         (cout2 (instantiate::pipe)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc e1 cout1 env)))))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc e2 cout2 env)))))
      (let ((a (pipe-get cout1))
            (b (pipe-get cout2)))
         (pipe-put cout
            (match-case op
               (+ (+ a b))
               (- (- a b))
               (* (* a b))
               (= (equal? a b))
               (< (< a b))
               (<= (<= a b))
               (> (> a b))
               (>= (>= a b))
               (and (and a b))
               (or (or a b))
               (else (error "eval-binary" "operator unknown" op)))))))

(define (eval-let bindings body cout env)
;   (print-x "eval-let, x = " x ", expr = " expr ", body = " body)
   (let ((env1 env))
      (let loop ((binds bindings))
         (if (pair? binds)
             (match-case (car binds)
                ((?x ?expr)
                 (let ((cout1 (instantiate::pipe)))
                    (eval-orc expr cout1 env)
                    (set! env1 (environment-add env1 x (pipe-get cout1)))
                    (loop (cdr binds)))))))
      (eval-orc body cout env1)))

(define (eval-let* bindings body cout env)
;   (print-x "eval-let*, x = " x ", expr = " expr ", body = " body)
   (let ((env1 env))
      (let loop ((binds bindings))
         (if (pair? binds)
             (match-case (car binds)
                ((?x ?expr)
                 (let ((cout1 (instantiate::pipe)))
                    (eval-orc expr cout1 env1)
                    (set! env1 (environment-add env1 x (pipe-get cout1)))
                    (loop (cdr binds)))))))
      (eval-orc body cout env1)))

(define (eval-if test e1 e2 cout env)
;   (print-x "eval-if")
   (let ((cout1 (instantiate::pipe)))
      (eval-orc test cout1 env)
      (let ((test (pipe-get cout1)))
;         (print-x "test = " test)
         (if test
             (eval-orc e1 cout env)
             (eval-orc e2 cout env)))))

(define (eval-letrec bindings body cout env)
   (let ((env1 env))
      (let loop ((binds bindings))
         (if (pair? binds)
             (match-case (car binds)
                ((?x ?expr)
                 (begin
                    (set! env1 (environment-add env1 x 'void))
                    (loop (cdr binds)))))))
      (let ((env2 env1))
         (let loop ((binds bindings))
            (if (pair? binds)
                (match-case (car binds)
                   ((?x ?expr)
                    (let ((cout1 (instantiate::pipe))
                          (tmp (gensym)))
                       (eval-orc expr cout1 env1)
                       (set! env2 (environment-add env2 tmp (pipe-get cout1)))
                       (eval-set! x tmp cout1 env2)
                       (loop (cdr binds)))))))
         (eval-orc body cout env1))))

(define (eval-rwait t cout env)
   (let ((cout1 (instantiate::pipe)))
      (eval-orc t cout1 env)
      (let ((t (pipe-get cout1)))
         (thread-sleep! (* 1000 t))
         (pipe-put cout 'signal))))

(define (eval-atom atom cout env)
;   (print-x "eval-atom, " atom)
   (cond
      ((symbol? atom)
       (eval-symbol atom cout env))
      (else (pipe-put cout atom))))

(define (eval-otherwise e1 e2 cout env)
   (let ((cout1 (instantiate::pipe)))
      (eval-orc e1 cout1 env)
      (let ((v (pipe-get cout1)))
         (match-case v
            (nothing (eval-orc e2 cout env))
            (else
             (pipe-put cout v) 
             (thread-start!
                (instantiate::pthread
                   (body
                      (lambda ()
                         (let loop ((v (pipe-get cout1)))
                            (pipe-put cout v)))))))))))

(define (eval-set! x expr cout env)
;   (print-x "eval-set!, x = " x ", expr = " expr)
   (let ((cout1 (instantiate::pipe)))
      (eval-orc expr cout1 env)
      (let ((v (pipe-get cout1)))
         ;(print-x x " -> " v.body)
         (environment-update env x v)
         ;(print "env updated")
         (pipe-put cout 'signal))))

(define (eval-ift test cout env)
   ;(print "eval-ift")
   (let ((cout1 (instantiate::pipe)))
      (eval-orc test cout1 env)
      (if (pipe-get cout1)
          (pipe-put cout 'signal))))

(define (eval-list expressions cout env)
;   (print "eval-list, expressions = " expressions)
   (let loop ((expressions expressions)
              (pipes (list)))
      (if (pair? expressions)
          (let ((expression (car expressions))
                (pipe (instantiate::pipe)))
             (thread-start!
                (instantiate::pthread
                   (body
                      (lambda ()
                         (eval-orc expression pipe env)))))
             (loop
                (cdr expressions)
                (cons pipe pipes)))
          (let loop ((pipes pipes)
                     (return (list)))
             (if (pair? pipes)
                 (loop
                    (cdr pipes)
                    (cons (pipe-get (car pipes)) return))
                 (pipe-put cout return))))))

(define (eval-orc expr cout env)
;   (print-x "eval-orc, expr = " expr); ", env = " env)
   (match-case expr
      ((atom ?atom) (eval-atom atom cout env))
      ((>> ?e1 ?x ?e2) (eval->> e1 x e2 cout env))
      ((// ?e1 ?e2) (eval-// e1 e2 cout env))
      ((<< ?e1 ?x ?e2) (eval-<< e1 x e2 cout env))
      ((otherwise ?e1 ?e2) (eval-otherwise e1 e2 cout env))
      ((+ ?e1 ?e2) (eval-binary '+ e1 e2 cout env))
      ((- ?e1 ?e2) (eval-binary '- e1 e2 cout env))
      ((* ?e1 ?e2) (eval-binary '* e1 e2 cout env))
      ((= ?e1 ?e2) (eval-binary '= e1 e2 cout env))
      ((< ?e1 ?e2) (eval-binary '< e1 e2 cout env))
      ((<= ?e1 ?e2) (eval-binary '<= e1 e2 cout env))
      ((> ?e1 ?e2) (eval-binary '> e1 e2 cout env))
      ((>= ?e1 ?e2) (eval-binary '>= e1 e2 cout env))
      (((kwote and) ?e1 ?e2) (eval-binary 'and e1 e2 cout env))
      (((kwote or) ?e1 ?e2) (eval-binary 'or e1 e2 cout env))
      ;((&& ?e1 ?e2) (eval-binary '&& e1 e2 cout env))
      ;((|| ?e1 ?e2) (eval-binary '|| e1 e1 cout env))
      ((let ?bindings ?body) (eval-let bindings body cout env))
      ((letrec ?bindings ?body) (eval-letrec bindings body cout env))
      ((let* ?bindings ?body) (eval-let* bindings body cout env))
      ((val (?x ?expr) ?body) (eval-val x expr body cout env))
      ((if ?test ?e1 ?e2) (eval-if test e1 e2 cout env))
      ((ift ?test) (eval-ift test cout env))
      ((rwait ?t) (eval-rwait t cout env))
      ;((symbole a) (eval-symbole 1 cout env))
      ((set! ?x ?expr) (eval-set! x expr cout env))
      ((lambda ?vars ?body) (eval-lambda vars body cout env))
      ((list . ?expressions) (eval-list expressions cout env))
      ((site-call ?proc . ?args) (eval-site-call proc args cout env))
      ((?proc . ?args) (eval-application proc args cout env))))

(define (orc-main expr)
   (let ((cout (instantiate::pipe)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (eval-orc expr cout env-empty)))))
      (let loop ((v (pipe-get cout)))
         (print-x v)
         (loop (pipe-get cout)))))

(define (main args)
   (let ((expr
            `(>> (// 1 2) x (// (+ x 10) (+ x 20)))))
            ;`(>> (// 10 (>> 20 x (- x 1))) y (+ y 1)))) ; -> 11, 20

            ; SEQUENTIAL
            ;`(>> 1 x x))) ; -> 1
            ;`(>> (// 1 2) x (+ x 10)))) ; -> 11, 12
            ;`(>> 1 x (// (+ x 10) (+ x 20))))) ; -> 11, 21
            ;`(>>
            ;    (// 1 2)
            ;    x
            ;    (// (+ x 10) (+ x 20))))) ; -> 11, 12, 21, 22

            ; PARALLEL
            ;`(// 1 2))) ; -> 1, 2
            ;`(// (>> 1 x (+ x 10)) 2))) ; -> 2, 11
            ;`(// 1 (>> 2 x (+ x 10))))) ; -> 1, 12
            ;`(// (>> 1 x (+ x 10)) (>> 2 x (+ x 20))))) ; -> 11, 22

            ; PRUNING
            ;`(<< x x 1))) ; -> 1
            ;`(<< x x (// 1 2)))) ; -> 1 OR 2
            ;`(<< (// (+ x 10) 100) x (// 1 2)))) ; -> 100, 11 OR 100, 12
            ;`(<< (// x 1) x (// (>> (rwait 1000) x 2) (>> (rwait 1000) x 3)))))
            ;`(<<
            ;    (// (+ x 100) (>> (// signal x) y 10))
            ;    x
            ;    (>>
            ;       (rwait 500)
            ;       z
            ;       (// 1 2)))))
            ;`(<< (// x 88) x (>> (rwait 2000) x 99))))
            ;`(<< (// (>> (+ 10 x) y (+ y x)) (>> (+ 20 x) y (+ y x))) x 1)))
            ;`(<< (// (+ x 10) (+ x 20)) x (>> (rwait 1000) x 100))))
            ;`(<< (<< (// (+ x y) (// x (// y 0))) y (>> (rwait 1000) a 1)) x (>> (rwait 2000) b 2))))
            
            ; OTHERWISE
            ;`(otherwise 1 2)))
            ;`(otherwise signal 2)))
            ;`(otherwise nothing 2)))
            ;`(otherwise (// 1 2) 3)))
            
            ; ASSOCIATIVITE DE //
            ;`(// 1 (// 2 3)))) ; -> 1, 2, 3
            ;`(// (// 1 2) 3))) ; -> 1, 2, 3

            ; ASSOCIATIVITE DE >>
            ;`(>> 1 x (>> (+ x 10) y (+ x y))))) ; -> 12
            ;`(>> (>> 1 x (+ x 10)) x (+ x 100)))) ; -> 111

            ; LAMBDA (un seul argument)
            ;`(lambda x x)))

            ; APPLICATION
            ;`((lambda (x) x) 1)))
            ;`((lambda (x y) (+ x y)) 1 2)))
            ;`((lambda (x) (+ x 1)) (- 5 1))))
            ;`((>> (rwait 3000) c (lambda (x y) (+ x y)))
            ;  (>> (rwait 1000) a 1)
            ;  (>> (rwait 2000) b 2))))
      
            ; NESTED
            ;`(+ 1 (// 2 3))))
            ;`(+ (// 1 2) (// 3 4))))

            ; LET une seule expression
            ;`(let ((x 1)) x)))
            ;`(let ((x 9)) (let ((y 12)) (// x y)))))
            ;`(let ((x 9)(y 12)) (// x y))))
            ;`(let ((x 9)(y x)) (// x y))))
            ;`(let ((x 2))
            ;    (let ((f (lambda (y) (+ x y))))
            ;       (let ((x 3))
            ;          (f 1))))))
            ;`(let ((f (lambda (x) (// x 99)))) (>> (f 1) x (f x)))))
            ;`(let ((f (// (>> (rwait 500) x 1) 2))) (// f f))))
            ;`(let ((f (lambda () (// (>> (rwait 500) x 1) 2)))) (// (f) (f)))))

            ; LET*
            ;`(let* ((x 1)(y x)) (// x y))))
            
            ; SET
            ;`(let ((x 0)) (>> (set! x 1) y x))))

            ; VAL
            ;`(val (x (>> (rwait 1000) y 10)) (// 20 (+ x 1))))) 

            ; IFT
            ;`(ift (= 0 0))))
            ;`(ift (= 1 0))))
            ;`(// (>> (ift (= 0 0)) x 0)
            ;    (>> (ift (= 1 0)) x 1))))
            
            ; AND, OR, <, <=, >, >=
            ;`#t))
            ;`(and #t #t)))
            ;`(and #t #f)))
            ;`(and #f #t)))
            ;`(and #f #f)))
            ;`(or #t #t)))
            ;`(or #f #t)))
            ;`(or #t #f)))
            ;`(or #f #f)))
            ;`(or (and #t (or #f #t)) (or #t #f)))) ; -> #t
            ;`(or (and #t (or #t #f)) (or #t #f)))) ; -> #t
            ;`(< 1 2)))
            ;`(< 3 2)))
            ;`(<= 1 1)))
            ;`(<= 1 0)))
            ;`(> 1 0)))
            ;`(> 1 1)))
            ;`(>= 1 1)))
            ;`(>= 0 1)))
            
            ; IF
            ;`(if #f 1 2)))
            ;`(if 1 2 3)))
            ;`(if (= 2 2) 1 2)))
            ;`(if #t 1 2)))
            
            ; LETREC (un seul binding et une seule expression)
            ;`(letrec ((f (lambda (n) (if (= n 0) 0 (+ (f (- n 1)) n))))) (f 5))))
            ;`(letrec ((f (lambda (x) (f x)))) (f 8))))
            ;`(letrec ((even (lambda (n) (if (= n 0) #t (odd (- n 1)))))
            ;          (odd (lambda (n) (if (= n 0) #f (even (- n 1))))))
            ;    (even 11))))
            ;`(let (even 0)
            ;    (let (odd 0)
            ;       (let (tmp1 (lambda n (if (= n 0) #t (odd (- n 1)))))
            ;          (let (tmp2 (lambda n (if (= n 0) #f (even (- n 1)))))
            ;             (>>
            ;                (set even tmp1)
            ;                a
            ;                (>>
            ;                   (set odd tmp2)
            ;                   b
            ;                   (even 11)))))))))
            ;`(letrec ((fibo (lambda (n) (if (= n 0) 0
            ;                                (if (= n 1) 1 (+ (fibo (- n 1)) (fibo (- n 2))))))))
            ;    (fibo 10))))
            
            ; RWAIT
            ;`(>> (rwait 1000) x x)))

            ; METRONOME
            ;`(letrec ((metronome (lambda (x) (// x (>> (rwait 1000) y (metronome (+ x 1)))))))
            ;    (metronome 0))))
            ;`(letrec ((metronome (lambda (x) (// signal (>> (rwait x) y (metronome x))))))
            ;    (metronome 1000))))
            
            ; TICK TOCK 
            ;`(let ((c 0)(z 0))
            ;    (letrec ((metronome
            ;                (lambda (x)
            ;                   (//
            ;                      signal
            ;                      (>> (rwait x) y (metronome x))))))
            ;       (>>
            ;          (//
            ;             (>> (metronome 100) x
            ;                (>>
            ;                   (set! c (- c 1)) a c))
            ;             (>> (rwait 50) x
            ;                (>> (metronome 100) x
            ;                   (>>
            ;                      (set! c (+ c 1)) a c))))
            ;          d
            ;          (>>
            ;             (set! z (+ z 1)) a z))))))
            
            ; LIST
            ;`(list 1 2 3)))

            ; FORK-JOIN
            ;`(let ((A (lambda () (>> (rwait 1000) a 10)))
            ;       (B (lambda () (>> (rwait 2000) a 20))))
            ;    (<< (<< (list x y) x (A)) y (B)))))
            ;`(let ((A (lambda () (>> (rwait 1000) a 10)))
            ;       (B (lambda () (>> (rwait 2000) a 20))))
            ;    (list (A) (B)))))
            
            ; STOP
            ;`stop))
            ;`(// 1 stop)))
            ;`(>> (// signal (// stop signal)) x 1)))

            ; TIMEOUT
            ;`(<< x x (>> (// (rwait 2000) (rwait 1000)) x "bbc timed out"))))
            ;`(<< x x (// (>> (rwait 2000) x false) (rwait 3000)))))

            ; SITE CALL
            ;`(let ((site (lambda (x y) (// 1 (+ x y)))))
            ;    (site-call site 1 2))))

            
            
      (orc-main expr)))
   