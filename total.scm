(module orc-total
   (library pthread)
   (export
      (class environment
         variable
         next-environment)
      (class environment-empty::environment)
      (class pipe
         (mutex (default (make-mutex)))
         (condition (default (make-condition-variable)))
         (items (default (list))))
      (abstract-class orc-ast%)
      
      (class orc-sequential::orc-ast%
         e1::orc-ast%
         x::bstring
         e2::orc-ast%)
      
      (class orc-parallel::orc-ast%
         e1::orc-ast%
         e2::orc-ast%)
      
      (class orc-pruning::orc-ast%
         e1::orc-ast%
         x::bstring
         e2::orc-ast%)
      
      (class orc-otherwise::orc-ast%
         e1::orc-ast%
         e2::orc-ast%)
      
      (class orc-atom::orc-ast%
         expr)

      (class variable
         name
         value
         status
         (mutex (default (make-mutex)))
         (condition (default (make-condition-variable)))))
   (main main))

;; PRINT-X

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

;; AST

(define (make-sequential::orc-sequential e1 x e2)
   (instantiate::orc-sequential
      (e1 e1)
      (x x)
      (e2 e2)))

(define (make-parallel::orc-parallel e1 e2)
   (instantiate::orc-parallel
      (e1 e1)
      (e2 e2)))

(define (make-pruning::orc-pruning e1 x e2)
   (instantiate::orc-pruning
      (e1 e1)
      (x x)
      (e2 e2)))

(define (make-otherwise::orc-otherwise e1 e2)
   (instantiate::orc-otherwise
      (e1 e1)
      (e2 e2)))

(define (make-atom::orc-atom e)
   (instantiate::orc-atom
      (expr e)))

(define-generic (count-publish expr::orc-ast%))

(define-method (count-publish expr::orc-sequential)
   (* (count-publish expr.e1)
      (count-publish expr.e2)))

(define-method (count-publish expr::orc-parallel)
   (+ (count-publish expr.e1)
      (count-publish expr.e2)))

(define-method (count-publish expr::orc-pruning)
   (count-publish expr.e1))

(define-method (count-publish expr::orc-otherwise)
   0)

(define-method (count-publish expr::orc-atom)
   1)

;; ENVIRONMENT

(define (make-environment-empty)
   (instantiate::environment-empty
      (variable class-nil)
      (next-environment class-nil)))

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

;; EVAL

(define-generic (orc-eval expr::orc-ast% cout::pipe env::environment))

(define-method (orc-eval expr::orc-sequential cout env)
   (let ((cout2 (instantiate::pipe)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (orc-eval expr.e1 cout2 env)))))
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
                                        (orc-eval
                                           expr.e2
                                           cout
                                           (environment-add env expr.x v))))))
                            (loop (pipe-get cout2)))))))))))


(define-method (orc-eval expr::orc-parallel cout env)
   ;(print-x "orc-eval parallel " expr)
   (thread-start!
      (instantiate::pthread
         (body
            (lambda () (orc-eval expr.e1 cout env)))))
   (thread-start!
      (instantiate::pthread
         (body
            (lambda () (orc-eval expr.e2 cout env))))))

(define-method (orc-eval expr::orc-pruning cout1 env1)
   (let ((cout2 (instantiate::pipe))
         (env2 (environment-add-no-value env1 expr.x)))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (orc-eval expr.e2 cout2 env1)
                  (environment-update env2 expr.x (pipe-get cout2))))))
      (thread-start!
         (instantiate::pthread
            (body
               (lambda ()
                  (orc-eval expr.e1 cout1 env2)))))))

(define-method (orc-eval expr::orc-otherwise cout env) 0)

(define-method (orc-eval expr::orc-atom cout env)
   ;(print-x "orc-eval atom " expr)
   ;(print "111 " expr)
   (pipe-put cout (expr.expr)))
   ;(print "222 " expr))

; PIPE

(define (make-pipe)
   (instantiate::pipe))

(define-generic (pipe-get c::pipe)
   ;(print-x "pipe-get")
   (mutex-lock! c.mutex)
   (let ((ret #f))
      (if (not (pair? c.items))
          (condition-variable-wait! c.condition c.mutex))
      (set! ret (car (reverse c.items)))
      (set! c.items (reverse (cdr (reverse c.items))))
      (mutex-unlock! c.mutex)
      ret))

(define-generic (pipe-put c::pipe item)
   ;(print-x "pipe-put " item)
   (mutex-lock! c.mutex)
   (set! c.items (cons item c.items))
   (condition-variable-signal! c.condition)
   (mutex-unlock! c.mutex))

;; VARIABLE

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

(define (fibo n)
   (case n
      ((0) 0)
      ((1) 1)
      (else (+ (fibo (- n 1)) (fibo (- n 2))))))

;; MAIN

(define (main args)
   (let ((expr (make-pruning
                  (make-atom (lambda () 1))
                  ;(make-parallel
                  ;   (make-atom (lambda () 1))
                  ;   (make-atom (lambda () 2)))
                  "x"
                  (make-parallel
                     (make-atom (lambda () 1))
                     (make-atom (lambda () 2)))))
         (cout (make-pipe))
         (env (make-environment-empty)))
      (orc-eval expr cout env)
      (let loop ((count (count-publish expr)))
         (if (not (equal? 0 count))
             (begin
                (print-x (pipe-get cout))
                (loop (- count 1)))))))
