;; ***** BEGIN LICENSE BLOCK *****
;; Roadsend PHP Compiler
;; Copyright (C) 2007-2008 Roadsend, Inc.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA
;; ***** END LICENSE BLOCK *****


;;;; Execute a PHP AST directly, without compiling.
(module evaluate
   (include "php-runtime.sch")
   (library php-runtime)
   (import (ast "ast.scm")
	   (declare "declare.scm")
	   (debugger "debugger.scm"))
   (export
    (generic evaluate node)
    (reset-evaluator-state)

    ;; some stuff exported just for the debugger
    *current-env*)
    
   (static
    (wide-class declared-function::function-decl
       canonical-name)
    
    (wide-class declared-static-var::static-decl
       name)
    
    (wide-class var/cached::var
       ;used to store the internal index to get at the value, in evaluate.scm
       (cached-env (default #f))
       (cached-index (default #f)))
    (wide-class function-invoke/cached::function-invoke
       cached-handle)    ))


;(define *global-env* (make-php-hash))
(define *current-env* 'unset)

;for functions and methods
(define *current-static-env* 'unset)

;the current escape function for return statements
(define *current-return-escape* 'unset)

;functions 1..n will break out 1..n levels
(define *break-stack* '())

;call this function to continue the current loop
(define *continue-stack* '())

(define *class-decl-table-for-eval* (make-hashtable))

;these are the functions that we need to remove from the function sig table to be
;clean for a fresh run.
(define *remove-from-fun-sig-table* '())

;for parent static method invocations -- they don't know who their daddy is.
(define *current-instance* 'unset)

(define *current-class-name* #f)
(define *current-function-name* #f)
(define *current-method-name* #f)

;for parent static method invocations -- they don't know who their daddy is.
(define *current-parent-class-name* 'unset)

(define (reset-evaluator-state)
   (set! *current-env* 'unset)
   (set! *current-static-env* 'unset)
   (set! *current-return-escape* 'unset)
   (set! *break-stack* '())
   (set! *continue-stack* '())
   (set! *class-decl-table-for-eval* (make-hashtable))
   (set! *current-instance* 'unset)
   (set! *current-parent-class-name* 'unset)
   (set! *current-class-name* #f)
   ;; XXX we should actually remove them !!!  --timjr 2006.3.22
   (set! *remove-from-fun-sig-table* '()))

; run after every page view
(add-end-page-reset-func reset-evaluator-state)


(define-generic (evaluate node)
   (cond
      ((list? node) (evaluate-block node))
      ((eqv? node :next) :next)
      ((eqv? node 'nop) #t) ; bad parse in interactive mode
      (else (error 'evaluate "Don't know what to do with node: "
                   (with-output-to-string
                      (lambda ()
                         (print-pretty-ast node)))))))

(define (d/evaluate node)
   "Call this instead of evaluate() for recusive calls.  It
gives the debugger a chance to run."
   (if *debugging?*
       (debug-hook node
		   (lambda () (evaluate node)))
       (evaluate node)))


(define-method (evaluate node::php-ast)
   (dynamically-bind (*current-env* *current-variable-environment*);*global-env*)
	 (bind-exit (return)
	    (dynamically-bind (*current-return-escape* return)
	       (with-access::php-ast node (real-filename nodes)
		  (set! *PHP-FILE* real-filename)
		  (d/evaluate nodes))))));)


(define-method (evaluate node::function-invoke)
   (with-access::function-invoke node (location name arglist)
      (set! *PHP-FILE* (cdr location))
      (set! *PHP-LINE* (car location))
      (begin0
       (if (ast-node? name)
	   ;don't cache non-constant function lookups
	   (eval-funcall (mkstr (d/evaluate name)) arglist)
	   (eval-funcall (mkstr name) arglist))
       (set! *PHP-FILE* (cdr location))
       (set! *PHP-LINE* (car location)))))

;;evaluate-default-value has been temporarily copied here from php-runtime.scm
;;because I had to copy php-funcall here
(define (evaluate-default-value value)
   "evaluate the default value of an optional argument"
   (match-case value
      (*zero* *zero*)
      (*one* *one*)
      ((quote ?FOO) FOO)
      ((lookup-constant ?CONST) (lookup-constant (mkstr CONST)))
      ((lookup-class-constant ?CLASS ?CONST) (lookup-class-constant (mkstr CLASS) (mkstr CONST)))
      ((convert-to-number ?FOO) (convert-to-number FOO))
      ;negative numeric literal
      ((php-- *zero* (convert-to-number ?NUM))
       (php-- *zero* (convert-to-number NUM)))
      ;constant in a builtin
      ((and (? symbol?) ?A)
       (lookup-constant (symbol->string A)))
      ;literal array
      ((let ((?NEWHASH (make-php-hash))) . ?REST)
       (let ((new-hash (make-php-hash)))
	  (for-each (lambda (insert-stmt)
		       (when (pair? insert-stmt)
			  (php-hash-insert! new-hash
					    (caddr insert-stmt)
					    (cadddr insert-stmt))))
		    REST)
	  new-hash))
      (?FOO FOO)))

;;there is a problem that, when evaluating the arguments for a
;;function call, if any hash-lookups are passed as references, they
;;need too be evaluated differently (as by get-location).
;;php-funcall in php-runtime.scm seems like the wrong place to have
;;that, but it's a shame to duplicate all of the function calling
;;machinery here.  still, that's what we've done for now.  See bug
;;2492. -- tpd 10/21/04
(define (eval-funcall call-name call-args)
   "do a function call at runtime"
   (let* ((sig (get-php-function-sig call-name))
	  (canonical-name (if sig (sig-canonical-name sig)))
	  (call-len (length call-args)))
      ;      (profile-enter canonical-name)
      ; 	  (arg-locations (map (lambda (arg)
      ; 				 (if (container? arg)
      ; 				     arg
      ; 				     (make-container arg)))
      ; 			      call-args)))
      (unless sig
	 ; no function signature, always fatal 
	 ; to simulate php we end manually if disable-errors is true
	 (if *errors-disabled*
	     (begin
		(php-warning "lookup-function - undefined function: " call-name)
		(exit -1))
	     (php-error "lookup-function - undefined function: " call-name)))
      (let ((the-function (sig-function sig)))
	 (unless the-function
	    (set! the-function
		  (or (hashtable-get *interpreted-function-table* canonical-name)
		      ;(eval canonical-name)
		      (error 'evaluate-funcall "function should be defined" sig)
		      ))
	    (sig-function-set! sig the-function))
	 [assert (the-function) (procedure? the-function)]
	 (php-check-arity sig call-name call-len)
	 (apply the-function
		(let ((args-num (if (sig-var-arity? sig)
				    call-len
				    (sig-length sig))))
		   ; pass each argument
		   (let loop ((i 0)
			      (call-args call-args)
			      (args '()))
		      (if (<fx i args-num)
			  (loop (+fx i 1)
				(gcdr call-args)
				(cons (if (<fx i call-len)
					  (if (sig-param-ref? (sig-ref sig i))
					      (maybe-box (get-location (car call-args)))
					      (maybe-unbox (d/evaluate (car call-args))))
					  ;when interpreting code, the function signatures have the _code_
					  ;for the default value in them
					  (evaluate-default-value (sig-param-default-value (sig-ref sig i))))
				      args))
			  (begin
			     ;(print "args is: " args ", args-num is " args-num)
			     (reverse! args)))))))))

(define-method (evaluate node::nop)
   '() )


(define (get-location node)
   (if (hash-lookup? node)
       (with-access::hash-lookup node (hash key)
	  (set! *PHP-LINE* (car (ast-node-location node)))
	  (let ((thehash (d/evaluate hash))
		(thekey (d/evaluate key)))
	     (container-value-set! thehash (%coerce-for-insert (container-value thehash)))
	     (if (php-hash? (container-value thehash))
		 (php-hash-lookup-location (container-value thehash) #t thekey)
		 (make-container (%general-lookup (container-value thehash) thekey)))))
       (d/evaluate node)))
   
(define-method (evaluate node::hash-lookup)
   (with-access::hash-lookup node (hash key)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let ((thehash (d/evaluate hash))
	    (thekey (d/evaluate key)))
	 (if (php-hash? (container-value thehash))
	     (php-hash-lookup-location (container-value thehash) #f thekey)
	     (make-container (%general-lookup (container-value thehash) thekey))))))

(define-method (evaluate node::literal-array)
   (with-access::literal-array node (array-contents)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let ((new-hash (make-php-hash)))
	 (map
	  (lambda (a)
	     (with-access::array-entry a (key value ref?)
		(php-hash-insert! new-hash
                                  (d/evaluate key)
				  (let ((val (d/evaluate value)))
				     (if ref?
					 (maybe-box val)
					 (maybe-unbox val))))))
	  array-contents)
	 new-hash)))

(define-method (evaluate node::postcrement)
   (with-access::postcrement node (crement lval)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let* ((var (d/evaluate lval))
	     (old-value (make-container (container-value var))))
	 (eval-assign lval
		      (ecase crement
			 ((--) (-- var));(php-- var 1))
			 ((++) (++ var))));(php-+ var 1))))
	 old-value)))

(define-method (evaluate node::precrement)
   (with-access::precrement node (crement lval)
      (set! *PHP-LINE* (car (ast-node-location node)))
      ;;get location is because of bug 2792.  see postcrement.
      (let ((var (d/evaluate lval)))
	 (eval-assign lval
		      (ecase crement
			 ((--) (-- var)) ;(php-- var 1))
			 ((++) (++ var)))) ;(php-+ var 1))))
	 var)))


(define-method (evaluate node::arithmetic-unop)
   (with-access::arithmetic-unop node (op a)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (ecase op
	     ((php-+) (d/evaluate a))
	     ((php--) (php-- 0 (d/evaluate a))))))


(define-method (evaluate node::assigning-arithmetic-op)
   (with-access::assigning-arithmetic-op node (op lval rval)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let ((a (d/evaluate lval))
	    (b (d/evaluate rval)))
	 (eval-assign lval
		      (ecase op
			 ((php-+) (php-+ a b))
			 ((php--) (php-- a b))
			 ((php-*) (php-* a b))
			 ((php-/) (php-/ a b))
			 ((php-%) (php-% a b))
			 ((bitwise-shift-left) (bitwise-shift-left a b))
			 ((bitwise-shift-right) (bitwise-shift-right a b))
			 ((bitwise-not) (bitwise-not b))
			 ((bitwise-or) (bitwise-or a b))
			 ((bitwise-xor) (bitwise-xor a b))
			 ((bitwise-and) (bitwise-and a b)))) )))

(define-method (evaluate node::assigning-string-cat)
   (with-access::assigning-string-cat node (lval rval)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (eval-assign lval (mkstr (d/evaluate lval) (d/evaluate rval)))))

(define-method (evaluate node::foreach-loop)
   (with-access::foreach-loop node (array key value body)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let ((array (copy-php-data (let ((a (maybe-unbox (d/evaluate array))))
                                     (if (and (php-object? a) (not (php-object-instanceof a "Traversable")))
                                         (convert-to-hash a)
					 ; Iterator/Aggregate will pass through
                                         a)))))
	 ; handle IteratorAggregate
	 (when (and (php-object? array) (php-object-instanceof array "IteratorAggregate"))
	    (set! array (maybe-unbox (call-php-method-0 array "getIterator")))
	    (unless (and (php-object? array)
			 (php-object-instanceof array "Iterator"))
	       (php-throw-builtin-exception "Object returned from getIterator() must implement interface Iterator")
	       (set! array #f)))
	 (if (not (or (php-hash? array) (php-object? array)))
	     (php-warning "Not an array or iterable object in foreach, variable is " (get-php-datatype array))
	     (bind-exit (break)
		(dynamically-bind (*break-stack* (cons break *break-stack*))
		   (if (php-object? array)
		       (call-php-method-0 array "rewind")
		       (php-hash-reset array))
		   (let ((started? #f))
		      ; the branch here is to avoid conditionals in the inner loop
		      (if (php-object? array)
			  (let loop ()
			     (if started?
				 (call-php-method-0 array "next")
				 (set! started? #t))
			     (when (convert-to-boolean (call-php-method-0 array "valid"))
				(eval-assign value (copy-php-data (call-php-method-0 array "current")))
				(unless (null? key)
				   (eval-assign key (copy-php-data (call-php-method-0 array "key"))))
				(bind-exit (continue)
				   (dynamically-bind (*continue-stack* (cons continue *continue-stack*))
						     (d/evaluate body)))
				(loop)))
			  (let loop ()
			     (if started?
				 (php-hash-advance array)
				 (set! started? #t))
			     (when (php-hash-has-current? array)
				(let ((key/value (php-hash-current array)))
				   (eval-assign value (copy-php-data (cdr key/value)))
				   (unless (null? key)
				      (eval-assign key (copy-php-data (car key/value)))))
				(bind-exit (continue)
				   (dynamically-bind (*continue-stack* (cons continue *continue-stack*))
						     (d/evaluate body)))
				(loop))))
		      ;
		      )))))))


(define-method (evaluate node::while-loop)
   (with-access::while-loop node (body condition)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (bind-exit (break)
	 (dynamically-bind (*break-stack* (cons break *break-stack*))
	    (let loop ()
	       (when (or (null? condition)
			 (convert-to-boolean (d/evaluate condition)))
		  (bind-exit (continue)
		     (dynamically-bind (*continue-stack* (cons continue *continue-stack*))
			(d/evaluate body)))
		  (loop)))))))



(define-method (evaluate node::for-loop)
   (with-access::for-loop node (init condition step body)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (bind-exit (break)
	 (dynamically-bind (*break-stack* (cons break *break-stack*))
	    (unless (null? init)
	       (d/evaluate init))
	    (let ((started? #f))
	       (let loop ()
		  ;this is to make sure that the step is executed even if the user does a continue
		  (if started?
		      (unless (null? step)
			 (d/evaluate step))
		      (begin
			 (set! started? #t)))
		  (if (or (null? condition) 
			  (convert-to-boolean (d/evaluate condition)))
		      (begin
			 (unless (null? body)
			    (bind-exit (continue)
			       (dynamically-bind (*continue-stack* (cons continue *continue-stack*))
				  (d/evaluate body))))
			 (loop)))))))))


(define-method (evaluate node::throw)
   (with-access::throw node (rval)
      (let ((except-obj (maybe-unbox (d/evaluate rval))))
	 (if (php-object? except-obj)
	     (if (php-object-is-a except-obj "Exception")
		 (php-exception except-obj)
		 (php-error "thrown exceptions must be derived from Exception base class"))
	     (php-error "can only throw objects")))))

;
; should we check out bigloo's exception handling instead?
;
; this is how we do it now:
; on the try-stack, save a list of (class_name_list . bind-exit-func)
; which push on at the begining of the try, and pop off at the end
; 
; in throw, run the try-stack, checking for matching subclass in the list, and calling
; the bind-exit with the matching class as an argument
;
; so if bind-exit returns a class name, we run the associated catch block
(define-method (evaluate node::try-catch)
   (bind-exit (caught)
      (with-access::try-catch node (try-body catches)
	 (set! *PHP-LINE* (car (ast-node-location node)))
	 ; extract class names we are catching for this try block
	 (let ((catch-classname-list '()))
	    (let loop ((clist catches))
	       (when (pair? clist)
		  (let ((current-catch (car clist)))
		     (with-access::catch current-catch (catch-class catch-var catch-body)
			(set! catch-classname-list (cons catch-class catch-classname-list)))
		     (loop (cdr clist)))))
	    ; add catch class name list to stack and run this try block
	    (let ((try-result (bind-exit (except)
				 (push-try-stack catch-classname-list except)
				 (d/evaluate try-body)
				 (pop-try-stack))))
	       (when (pair? try-result)
		  ; we excepted: pop the try stack and run the correct catch block
		  (pop-try-stack)
		  (let loop ((clist catches))
		     (when (pair? clist)
			(let ((current-catch (car clist)))
			   (with-access::catch current-catch (catch-class catch-var catch-body)
			      ; is this our catch class?
			      (when (string=? (mkstr catch-class) (mkstr (car try-result)))
				 ; yes, this is our catch block. eval.
				 (eval-assign catch-var (cdr try-result))
				 (d/evaluate catch-body)
				 (caught #t))))
			(loop (cdr clist))))))))))
      

(define-method (evaluate node::break-stmt)
   (with-access::break-stmt node (level)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let ((level (if (null? level)
		       0
		       (max 0 (- (mkfixnum (d/evaluate level)) 1)))))
	 (if (>= level (length *break-stack*))
	     (php-error/loc
	      node
	      (format "Cannot break ~A level~A" (+ level 1) (if (> level 0) "s" "")))
	     ((list-ref *break-stack* level) #t)))))

(define-method (evaluate node::return-stmt)
   (with-access::return-stmt node (value)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (*current-return-escape* (d/evaluate value))))


(define-method (evaluate node::exit-stmt)
   (with-access::exit-stmt node (rval)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (if (null? rval)
	  (php-funcall 'exit)
	  (php-funcall 'exit (d/evaluate rval)))))

(define-method (evaluate node::continue-stmt)
   (with-access::continue-stmt node (level)
      (set! *PHP-LINE* (car (ast-node-location node)))
      (let ((level (if (null? level)
		       0
		       (max 0 (- (mkfixnum (d/evaluate level)) 1)))))
	 (if (>= level (length *continue-stack*))
	     (php-error/loc
	      node
	      (format "Cannot continue ~A level~A" (+ level 1) (if (> level 0) "s" "")))
	     ((list-ref *continue-stack* level) #t)))))


(define-method (evaluate node::if-stmt)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::if-stmt node (condition then else)
      (if (convert-to-boolean (d/evaluate condition))
	  (d/evaluate then)
	  (d/evaluate else))))

(define-method (evaluate node::lyteral)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (lyteral-value node))

(define-method (evaluate node::literal-integer)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (convert-to-number (lyteral-value node)))

(define-method (evaluate node::literal-float)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (convert-to-number (lyteral-value node)))

(define-method (evaluate node::typecast)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::typecast node (typecast rval)
	 (let ((rval (d/evaluate rval)))
	    (ecase typecast
	       ((boolean) (convert-to-boolean rval))
	       ((object) (convert-to-object rval))
	       ((integer) (convert-to-integer rval))
	       ((float) (convert-to-float rval))
	       ((string) (convert-to-string rval))
	       ((hash) (convert-to-hash rval))))))

(define-method (evaluate node::arithmetic-op)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::arithmetic-op node (op a b)
      (let ((a (d/evaluate a))
	    (b (d/evaluate b)))
	 (ecase op
	    ((php--) (php-- a b))
	    ((php-+) (php-+ a b))
	    ((php-/) (php-/ a b))
	    ((php-*) (php-* a b))
	    ((php-%) (php-% a b))) )))


(define-method (evaluate node::echo-stmt)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::echo-stmt node (stuff)
      (if (list? stuff)
	  (dolist (l stuff)
	     (echo (d/evaluate l)))
	  (echo (d/evaluate stuff)))))

(define-method (evaluate node::global-decl)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::global-decl node (var)
      (let ((var-name (if (ast-node? var)
			  (mkstr (d/evaluate var))
			  (undollar var))))
	 (env-extend *current-env* var-name
		     (env-lookup *global-env* var-name)))))


(define-method (evaluate node::declared-static-var)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::declared-static-var node (name)
	 (env-extend *current-env* (undollar name)
		     (env-lookup *current-static-env* (undollar name)))))

(define-method (evaluate node::disable-errors)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::disable-errors node (body)
      (dynamically-bind (*errors-disabled* #t)
	 (d/evaluate body) )))

(define-method (evaluate node::var)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (let ((name (undollar (var-name node))))
      (let ((index (env-lookup-internal-index *current-env* name)))
	 (widen!::var/cached node
	    (cached-env *current-env*)
	    (cached-index index))
	 (env-internal-index-value index))))

(define-method (evaluate node::var/cached)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::var/cached node (name cached-env cached-index)
      ;either we have to eq? the env, or we'd have to make a backpatch list
      ;and clear the cached values, since a new env will have new entries 
      (if (and cached-index (eq? cached-env *current-env*))
	  (env-internal-index-value cached-index)
	  (let ((index (env-lookup-internal-index *current-env* (undollar name))))
	     (set! cached-index index)
	     (set! cached-env *current-env*)
	     (env-internal-index-value index)))))
	  

(define-method (evaluate node::var-var)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::var-var node (lval)
      (var-lookup *current-env* (mkstr (d/evaluate lval)))))
	

(define-method (evaluate node::assignment)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::assignment node (lval rval)
      (eval-assign lval (copy-php-data (d/evaluate rval)) )))

(define-generic (eval-assign lval rval)
   (let ((lval (d/evaluate lval)))
;      (if (container? lval)
;	  (begin
	     (container-value-set! lval (maybe-unbox rval))
	     ;XXX not sure which container I should return -- left or right
	     lval))
;	  (error 'assign
;		 "I'm not sure what to do when I don't have a container lval"
;		 (mkstr lval)))))

(define-method (eval-assign lval::hash-lookup rval)
   (do-hash-assign lval (maybe-unbox rval)))

(define (do-hash-assign lval rval)
   (with-access::hash-lookup lval (hash key)
      (if (hash-lookup? hash)
	  ;;if it's a nested hash lookup, evaluate all the keys and pass a
	  ;;list of them into %general-insert-n!, since recursively calling
	  ;;eval-assign causes us to multiply-evaluate the key forms
	  (let loop ((keys (list (d/evaluate key)))
		     (next hash))
	     (if (hash-lookup? next)
		 (with-access::hash-lookup next (hash key)
		    (loop (cons (d/evaluate key) keys)
			  hash))
		 ;;in the base case, we're assigning into a variable or property-lookup
		 ;;or something, so call eval-assign recursively
		 (eval-assign next (%general-insert-n! (%coerce-for-insert (maybe-unbox (d/evaluate next)))
						       keys
                                                       ;; ugh
                                                       (map (lambda (a) #f) keys)
						       rval))))
	  ;;no nested lookup, just insert the value
	  ;;assign back the
	  ;;hash (in case it needed to be coerced) or string (in case
	  ;;the string was modified)
	  ;;
	  ;; BUT don't assign if it was an object, which happens for ArrayAccess implementations
	  (let ((assign-obj (%coerce-for-insert (maybe-unbox (d/evaluate hash)))))
	     (if (php-object? assign-obj)
		 (%general-insert! assign-obj (d/evaluate key) rval)
		 (eval-assign hash (%general-insert! assign-obj
						     (d/evaluate key)
						     rval))))))
   rval)


(define-method (eval-assign lval::property-fetch rval)
   (with-access::property-fetch lval (obj prop)
      (let* ((obj-val (maybe-unbox (d/evaluate obj)))
	     (prop-val (maybe-unbox (d/evaluate prop)))
	     (access-type (php-object-property-visibility obj-val prop-val *current-instance*)))
	 (when (pair? access-type)
	    (let ((vis (car access-type)))
	       (php-error (format "Cannot access ~a property ~a::$~a" vis (php-object-class obj-val) prop-val))))	 
	 (php-object-property-set! obj-val
				   prop-val
				   (maybe-unbox rval)
				   access-type))))

(define-method (eval-assign lval::static-property-fetch rval)
   (with-access::static-property-fetch lval (class prop)
      (let ((class-canon (cond ((eqv? class '%self) *current-class-name*)
			       ((eqv? class '%parent) (if *current-class-name*
							 (php-class-parent-class *current-class-name*)
							 #f))
			       (else class))))
	 (when (and (eqv? class '%self)
		    (eqv? class-canon #f))
	    (php-error "Cannot access self:: when no class scope is active"))
	 (when (and (eqv? class '%parent)
		    (or (eqv? class-canon #f)))
	    (php-error "Cannot access parent:: when current class scope has no parent"))
	 (let* ((prop-val (if (var-var? prop)
			      (maybe-unbox (d/evaluate prop))
			      prop))
		(prop-name (undollar (var-name prop-val)))
		(access-type (php-class-static-property-visibility class-canon prop-name *current-class-name*)))
	    (when (pair? access-type)
	       (let ((vis (car access-type)))
		  (php-error (format "Cannot access ~a static property ~a::$~a" vis class prop-name))))
	    (php-class-static-property-set! class-canon prop-name (maybe-unbox rval) access-type)))))


(define-method (evaluate node::list-assignment)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::list-assignment node (lvals rval)
      (let ((rval (d/evaluate rval)))
	 (if (convert-to-boolean rval)
	     (let ((rval (convert-to-hash rval)))
		;; zend goes thru the list backwards for some reason.. see bug 2611
		(for-each
		 (let ((i (- (length lvals) 1)))
		    (lambda (lval)
		       (unless (null? lval)
			  (eval-assign lval (php-hash-lookup rval i)))
		       (set! i (- i 1))))
		 (reverse lvals))
		rval)
	     ; if rval was empty, zend will set the items in the list to NULL
	     (begin
		(for-each
		 (lambda (lval)
		    (unless (null? lval)
		       (eval-assign lval NULL)))
		 (reverse lvals))
		#f)))))

(define-method (evaluate node::reference-assignment)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::reference-assignment node (lval rval)
      (if (or (function-invoke? rval)
              (method-invoke? rval)
              (constructor-invoke? rval)
              (static-method-invoke? rval)
              (parent-method-invoke? rval))
          ;; maybe emit a strict warning?
          (let ((rval-value (maybe-box (get-location rval))))
             (if (container-reference? rval-value)
                 (update-location lval rval-value)
                 (eval-assign lval (maybe-unbox rval-value))))
          (let ((rval-value (maybe-box (get-location rval))))
             (container->reference! (update-location lval rval-value))
             rval-value))))


(define-generic (update-location lval rval)
   (error 'update-location "don't know how to update location" (mkstr lval)))

(define-method (update-location lval::var rval)
   (let ((name (undollar (var-name lval))))
      (let ((index (env-lookup-internal-index *current-env* name)))
	 (widen!::var/cached lval
	    (cached-index index)
	    (cached-env *current-env*))
	 (env-internal-index-value-set! index rval))))


(define-method (update-location lval::var-var rval)
   (with-access::var-var lval (lval)
      (let ((name (mkstr (d/evaluate lval))))
	 (env-extend *current-env* name rval))))

(define-method (update-location lval::var/cached rval)
   (with-access::var/cached lval (name cached-index cached-env)
      ;either we have to eq? the env, or we'd have to make a backpatch list
      ;and clear the cached values, since a new env will have new entries 
      (if (and cached-index (eq? cached-env *current-env*))
	  (env-internal-index-value-set! cached-index rval)
	  (let ((index (env-lookup-internal-index *current-env* (undollar name))))
	     (set! cached-env *current-env*)
	     (set! cached-index index)
	     (env-internal-index-value-set! index rval)))))

(define-method (update-location lval::hash-lookup rval)
   (do-hash-assign lval (maybe-box rval)))

(define-method (update-location lval::property-fetch rval)
   (with-access::property-fetch lval (obj prop)
      (let* ((obj-val (maybe-unbox (d/evaluate obj)))
	     (prop-val (maybe-unbox (d/evaluate prop)))
	     (access-type (php-object-property-visibility obj-val prop-val *current-instance*)))
	 (when (pair? access-type)
	    (let ((vis (car access-type)))
	       (php-error (format "Cannot access ~a property ~a::$~a" vis (php-object-class obj-val) prop-val))))	 	 
	 (php-object-property-set! obj-val
				   prop-val
				   rval
				   access-type))))
				
(define-method (evaluate node::unset-stmt)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::unset-stmt node (lvals)
      (for-each unset lvals)))


(define-method (evaluate node::isset-stmt)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::isset-stmt node (rvals)
      (if (pair? rvals)
	  (let loop ((a (car rvals))
		     (vars (cdr rvals)))
	     (if (isset a)
		 (if (pair? vars)
		     (loop (car vars) (cdr vars))
		     #t)
		 #f))
	  #f)))

(define-method (evaluate node::empty-stmt)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::empty-stmt node (rval)
      (bind-exit (return)
	 (when (and (hash-lookup? rval) (not (isset rval)))
	    (return #t))
	 (let ((r (maybe-unbox (d/evaluate rval))))
	    (php-empty? r)))))

(define-generic (isset rval)
   (not (null? (maybe-unbox (d/evaluate rval)))))

(define-method (isset rval::hash-lookup)
   (with-access::hash-lookup rval (hash key)
      (let ((obj (container-value (d/evaluate hash))))
	 (if (and (php-object? obj) (php-object-instanceof obj "ArrayAccess"))
	     (convert-to-boolean (call-php-method-1 obj "offsetExists" (d/evaluate key)))
	     ; normal
	     (not (null? (maybe-unbox (d/evaluate rval))))))))
	     
(define-method (isset rval::property-fetch)
   (with-access::property-fetch rval (obj prop)
      (let* ((obj-e (maybe-unbox (d/evaluate obj)))
	     (prop-e (mkstr (maybe-unbox (d/evaluate prop))))
	     (access-type (php-object-property-visibility obj-e prop-e *current-instance*)))
	 (if (and (php-object? obj-e)
		  (php-class-method-exists?
		   (php-object-class obj-e)
		   "__isset")
		  ; we call __isset when the caller doesn't have visibility access
		  ; (whether it's actually declared for real or not) or when it
		  ; would have visibility but it's not declared
		  (or  (pair? access-type) ; if access-type is a pair, it's not visible in this context
		       (not (php-object-has-declared-property?
			     obj-e
			     prop-e))))
	     (convert-to-boolean (call-php-method-1 obj-e "__isset" prop-e))
	     ; normal isset
	     (not (null? (maybe-unbox (d/evaluate rval))))))))	     

(define (%unset-eval-assign orig-lval)
   (let ((lval (d/evaluate orig-lval)))
      (if (container-reference? lval)
	  ; variable was a reference: detach from the reference and set NULL
	  (update-location orig-lval (make-container NULL))
	  ; normal eval-assign
	  (container-value-set! lval NULL))
      lval))

(define-generic (unset lval)
   (%unset-eval-assign lval))

(define-method (unset lval::property-fetch)
   (with-access::property-fetch lval (obj prop)
      (let* ((obj-e (maybe-unbox (d/evaluate obj)))
	     (prop-e (mkstr (maybe-unbox (d/evaluate prop))))
	     (access-type (php-object-property-visibility obj-e prop-e *current-instance*)))
	 (if (and (php-object? obj-e)
		  (php-class-method-exists?
		   (php-object-class obj-e)
		   "__unset")
		  ; we call __unset when the caller doesn't have visibility access
		  ; (whether it's actually declared for real or not) or when it
		  ; would have visibility but it's not declared
		  (or  (pair? access-type) ; if access-type is a pair, it's not visible in this context
		       (not (php-object-has-declared-property?
			     obj-e
			     prop-e))))
	     (begin
		(call-php-method-1 obj-e "__unset" prop-e)
		; always return null
		NULL)
	     ; unset (remove) property
	     (php-object-property-unset obj-e prop-e)))))

(define-method (unset lval::hash-lookup)
   (with-access::hash-lookup lval (hash key)
      (let ((hash (container-value (d/evaluate hash))))
	 (when (string? hash)
	    (php-error "Cannot unset string offsets"))
	 (if (and (php-object? hash) (php-object-instanceof hash "ArrayAccess"))
	     (call-php-method-1 hash "offsetUnset" (d/evaluate key))
	     (when (php-hash? hash)
		(if (eqv? key :next)
		    (php-warning "Array unset not supported with empty [], Loc: " (ast-node-location lval) )
		    (php-hash-remove! hash
				      (d/evaluate key))))))))

(define-method (evaluate node::switch-stmt)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::switch-stmt node (rval cases)
      (bind-exit (break)
	 (dynamically-bind (*break-stack* (cons break *break-stack*))
	    ;I think they do the same thing, in the case of a switch statement -tpd
	    (dynamically-bind (*continue-stack* (cons break *continue-stack*))
	       (let ((switch-flag #f)
		     (switch-var (d/evaluate rval)))
		  (for-each
		   (lambda (c)
		      (if (default-switch-case? c)
			  (with-access::default-switch-case c (body)
			     (set! switch-flag #t)
			     (d/evaluate body))			  
			  (with-access::switch-case c (val body)
			     (when (or switch-flag
				       (equalp switch-var (d/evaluate val)))
				(set! switch-flag #t)
				(d/evaluate body)))))
		   cases)))))))
	 
(define-method (evaluate node::do-loop)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::do-loop node (condition body)
      (bind-exit (break)
	 (dynamically-bind (*break-stack* (cons break *break-stack*))
	    (let loop ()
	       (bind-exit (continue)
		  (dynamically-bind (*continue-stack* (cons continue *continue-stack*))
		     (d/evaluate body)))
	       (when (or (null? condition)
			 (convert-to-boolean (d/evaluate condition)))
		  (loop)))))))



(define (add-arguments-to-env function-name env args params)
   ;we assume that we'll never have more args than params, because PHP can't define
   ;var-arity functions, just optional params
   (let loop ((args args)
  	      (params params)
	      (argnum 1))
      (unless (null? params)
	 (let ((param-val
		(if (null? args)
		    (if (required-formal-param? (car params))
			NULL
			(d/evaluate (optional-formal-param-default-value (car params))))
		    (car args))))
	    
	    ; type hint check
	    ; from the parser, this will either come in as an id (class name), '%array
	    ; or null (no type hint)
	    (unless (null? (formal-param-typehint (car params)))
	       (let ((allow-null? (and (optional-formal-param? (car params))
				       (literal-null? (optional-formal-param-default-value (car params)))))
		     (param-val (maybe-unbox param-val)))
		  (if (eqv? '%array (formal-param-typehint (car params)))
		      ; needs to be php-hash, or NULL if we allowed that as a default
		      (unless (or (php-hash? param-val)
				  (and allow-null?
				       (php-null? param-val)))
			 (php-recoverable-error (format "Argument ~a passed to ~a() must be an array, ~a given, called in ~a on line ~a and defined"
							argnum
							function-name
							(get-php-datatype param-val)
							(get-stack-caller-file)
							(get-stack-caller-line)
							)))
		      ; needs to be an object
		      (unless (or (and (php-object? param-val)
				       (php-object-is-a param-val (formal-param-typehint (car params))))
				  (and allow-null?
				       (php-null? param-val)))
			 ; to give the proper error, we need to know if the typehint is an interface or an object
			 (let ((emsg (if (php-class-is-interface? (formal-param-typehint (car params)))
					 (mkstr "implement interface " (formal-param-typehint (car params)))
					 (mkstr "be an instance of " (formal-param-typehint (car params))))))
			    (php-recoverable-error (format "Argument ~a passed to ~a() must ~a, ~a given, called in ~a on line ~a and defined"
							   argnum
							   function-name
							   emsg
							   (if (php-object? param-val)
							       (mkstr "instance of " (php-object-class param-val))
							       (get-php-datatype param-val))
							   (get-stack-caller-file)
							   (get-stack-caller-line)
							   )))))))
	    ;
	    (env-extend env (undollar (formal-param-name (car params)))
			(maybe-box
			 (if (formal-param-ref? (car params))
			     param-val
			     (copy-php-data param-val) ))))
	 (loop (gcdr args) (cdr params) (+ 1 argnum)))))

(define (%check-typehints decl-arglist)
   ; if an argument has a type hint, the default value is only allowed to be NULL
   (for-each (lambda (a)
		; array
		(when (and (optional-formal-param? a)
			   (and (eqv? '%array (optional-formal-param-typehint a))
				(or (not (literal-null? (optional-formal-param-default-value a)))
				    (not (literal-array? (optional-formal-param-default-value a))))))
		   (php-error "Default value for parameters with array type hint can only be an array or NULL"))
		; class id
		(when (and (optional-formal-param? a)
			   (and (and (not (eqv? '%array (optional-formal-param-typehint a)))
				     (not (null? (optional-formal-param-typehint a))))
				(not (literal-null? (optional-formal-param-default-value a)))))
		   (php-error "Default value for parameters with a class type hint can only be NULL")))
	     decl-arglist))		   

(define-method (evaluate node::class-decl)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (unless (hashtable-get *class-decl-table-for-eval* (class-decl-name node))
      (%do-class-declare node)
      (hashtable-put! *class-decl-table-for-eval* (class-decl-name node) #t)))

(define-method (evaluate node::constructor-invoke)
   (with-access::constructor-invoke node (location class-name arglist)
       (set! *PHP-FILE* (cdr location))
       (set! *PHP-LINE* (car location))
       (begin0
	(let* ((class-name (maybe-unbox (d/evaluate class-name)))
	       (accessible (php-class-constructor-accessible
			    class-name
			    *current-class-name*)))
	   (when (pair? accessible)
	      (let ((vis (car accessible))
		    (constructor-name (cdr accessible)))
		 (php-error (format "Call to ~a ~a::~a() from invalid context"
				    vis
				    class-name
				    constructor-name))))
	   (make-container
	    (apply construct-php-object class-name
		   (map d/evaluate arglist))))
	(set! *PHP-FILE* (cdr location))
	(set! *PHP-LINE* (car location)))))


;       (apply instantiate-php-class (d/evaluate class-name)
; 	     (map evaluate arglist))))

(define-method (evaluate node::method-invoke)
   (with-access::method-invoke node (location method arglist)
      (with-access::property-fetch method (obj prop)
	 (set! *PHP-FILE* (cdr location))
	 (set! *PHP-LINE* (car location))
	 (begin0
	  (let* ((object (maybe-unbox (d/evaluate obj)))
		 (method-name (d/evaluate prop))
		 (accessible (php-method-accessible object
						    method-name
						    *current-class-name*)))
						    ;(if (eqv? *current-instance* object)
						;	; current-class context
						;	*current-class-name*
						;	; no context
						;	#f))))
	     
	     ;;XXX okay, this is a problem, because we don't know if
	     ;;we're getting the location or getting the value, so we
	     ;;don't know what to do with hash lookups and the like.
	     ;;err on the side of locations.
	     
	     (if (php-object? object)
		 (begin
		    (when (pair? accessible)
		       (let ((vis (car accessible))
			     (origin-class (cdr accessible)))
			  (php-error (format "Call to ~a method ~a::~a() from context '~a'"
					     vis
					     origin-class
					     method-name
					     (if *current-class-name* *current-class-name* "")))))
		    (apply call-php-method object method-name (map get-location arglist)))
		 (php-error/loc obj (format "method call on non-object, object is |~A|" (mkstr object)))))
	  (set! *PHP-FILE* (cdr location))
	  (set! *PHP-LINE* (car location))))))


(define-method (evaluate node::static-method-invoke)
   (with-access::static-method-invoke node (location class-name method arglist)
      (set! *PHP-FILE* (cdr location))
      (set! *PHP-LINE* (car location))
      (let ((class-canon (cond ((eqv? class-name '%self) *current-class-name*)
			       (else class-name))))
	 (when (and (eqv? class-name '%self)
		    (eqv? class-canon #f))
	    (php-error "Cannot access self:: when no class scope is active"))
	 (begin0
	  (let* ((method-name (d/evaluate method))
		 (accessible (php-method-accessible class-canon method-name *current-class-name*)))
	     (when (pair? accessible)
		(let ((vis (car accessible))
		      (origin-class (cdr accessible)))
		   (php-error (format "Call to ~a method ~a::~a() from context '~a'"
				      vis
				      origin-class
				      method-name
				      (if *current-class-name* *current-class-name* "")))))
	     (if (and (php-object? *current-instance*)
		      (php-object-is-subclass *current-instance* class-name))
		 ;; we only provide the static method call with a $this
		 ;; if the current instance is a subclass of the class
		 ;; the method is in.
		 ;	      (apply call-php-method *current-instance* method-name (map get-location arglist))
		 (apply call-static-php-method class-canon *current-instance* method-name (map get-location arglist))
		 (apply call-static-php-method class-canon NULL method-name (map get-location arglist))))
	  (set! *PHP-FILE* (cdr location))
	  (set! *PHP-LINE* (car location))))))


    
(define-method (evaluate node::parent-method-invoke)
   (with-access::parent-method-invoke node (location name arglist)
      (set! *PHP-FILE* (cdr location))
      (set! *PHP-LINE* (car location))
      (when (eqv? 'unset *current-parent-class-name*)
	 (php-error/loc node "Parent method invoked outside of a class"))
      (set! *PHP-LINE* (car location))
      (begin0
	 (let ((method-name (d/evaluate name)))
	    (apply call-php-parent-method
		   *current-parent-class-name*
		   (if (eqv? *current-instance* 'unset)
		       (make-container '())
		       *current-instance*)
		   method-name
		   (map get-location arglist)))	 
	 (set! *PHP-FILE* (cdr location))
	 (set! *PHP-LINE* (car location)))))


(define-method (evaluate node::static-property-fetch)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::static-property-fetch node (class prop)
      (let ((class-canon (cond ((eqv? class '%self) *current-class-name*)
			       ((eqv? class '%parent) (php-class-parent-class *current-class-name*))
			       (else class))))
	 (when (and (eqv? class '%self)
		    (eqv? class-canon #f))
	    (php-error "Cannot access self:: when no class scope is active"))
	 (when (and (eqv? class '%parent)
		    (or (eqv? class-canon #f) (eqv? class-canon 'stdclass)))
	    (php-error "Cannot access parent:: when current class scope has no parent"))
	 (let* ((prop-val (if (var-var? prop)
			      (maybe-unbox (d/evaluate prop))
			      prop))
		(prop-name (undollar (var-name prop-val)))
		(access-type (php-class-static-property-visibility class-canon prop-name *current-class-name*)))
	    (when (pair? access-type)
	       (let ((vis (car access-type)))
		  (php-error (format "Cannot access ~a static property ~a::$~a" vis class prop-name))))
	    (php-class-static-property-location class-canon prop-name access-type)))))

(define-method (evaluate node::property-fetch)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::property-fetch node (obj prop)
      (let* ((obj-val (maybe-unbox (d/evaluate obj)))
	    (prop-val (maybe-unbox (d/evaluate prop)))
	    (access-type (php-object-property-visibility obj-val prop-val *current-instance*)))
	 (when (pair? access-type)
	    (let ((vis (car access-type)))
	       (php-error (format "Cannot access ~a property ~a::$~a" vis (php-object-class obj-val) prop-val))))
	 (php-object-property-location obj-val prop-val access-type))))

(define-method (evaluate node::class-constant-fetch)
   (with-access::class-constant-fetch node (location class name)
      (set! *PHP-LINE* (loc-line location))
      ;; we just make-container here because the evaluator expects
      ;; everything to be in one.
      (let ((class-canon (cond ((eqv? class '%self) *current-class-name*)
			       ((eqv? class '%parent) (php-class-parent-class *current-class-name*))
			       (else class))))
	 (when (and (eqv? class '%self)
		    (eqv? class-canon #f))
	    (php-error "Cannot access self:: when no class scope is active"))
	 (when (and (eqv? class '%parent)
		    (or (eqv? class-canon #f) (eqv? class-canon 'stdclass)))
	    (php-error "Cannot access parent:: when current class scope has no parent"))
	 ;
	 (make-container (lookup-class-constant class-canon name)))))

(define-method (evaluate node::obj-clone)
   (with-access::obj-clone node (obj)
      (let ((obj-val (maybe-unbox (d/evaluate obj))))
	 (if (php-object? obj-val)
	     (clone-php-object obj-val)
	     (begin
		(php-warning "clone on non object")
		NULL)))))

(define-method (evaluate node::declared-function)
   (set! *PHP-LINE* (car (ast-node-location node)))
   '())


(define-method (evaluate node::constant-decl)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::constant-decl node (name value insensitive?)
      (let ((real-name (if (ast-node? name)
			  (mkstr (maybe-unbox (d/evaluate name)))
			  (mkstr name))))
	 (if (null? insensitive?)
	     (store-constant real-name (maybe-unbox (d/evaluate value)) #f)
	     (store-constant real-name (maybe-unbox (d/evaluate value))
			     (convert-to-boolean (d/evaluate insensitive?)))))))

(define-method (evaluate node::php-constant)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::php-constant node (name)
      (let ((name (mkstr name)))
	 (cond ((string=? "__CLASS__" name)
		*current-class-name*)
	       ((string=? "__FUNCTION__" name)
		*current-function-name*)
	       ((string=? "__METHOD__" name)
		*current-method-name*)
		(else
		 (lookup-constant name))))))

(define-method (evaluate node::string-cat)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::string-cat node (a b)
      (mkstr (d/evaluate a) (d/evaluate b))))

(define-method (evaluate node::bitwise-op)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (let ((a (d/evaluate (bitwise-op-a node)))
	 (b (d/evaluate (bitwise-op-b node)))
	 (op (bitwise-op-op node)))
      (ecase op
	 ((bitwise-or) (bitwise-or a b))
	 ((bitwise-xor) (bitwise-xor a b))
	 ((bitwise-and) (bitwise-and a b))
	 ((bitwise-shift-left) (bitwise-shift-left a b))
	 ((bitwise-shift-right) (bitwise-shift-right a b))
	 (else (error 'evaluate-bitwise-op "don't know of operation" op)))))

(define-method (evaluate node::bitwise-not-op)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (bitwise-not (d/evaluate (bitwise-not-op-a node))))


(define-method (evaluate node::comparator)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::comparator node (op (l p) (r q))
      (let ((p (d/evaluate l))
	    (q (d/evaluate r)))
	 (ecase op
	    ((equalp) (equalp p q))
	    ((not-equal-p) (not (equalp p q)))
	    ((identicalp) (identicalp p q))
	    ((not-identical-p) (not-identical-p p q))
	    ((less-than-p) (less-than-p p q))
	    ((less-than-or-equal-p) (less-than-or-equal-p p q))
	    ((greater-than-p) (greater-than-p p q))
	    ((greater-than-or-equal-p) (greater-than-or-equal-p p q))
	    ((instanceof) (begin
			     (when (lyteral? l)
				(php-error "instanceof expects an object instance"))
			     (php-object-instanceof p q))
	    )))))

(define-method (evaluate node::boolean-not)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::boolean-not node (p)
      (not (convert-to-boolean (d/evaluate p)))))


(define-method (evaluate node::boolean-or)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::boolean-or node (p q)
      (or (convert-to-boolean (d/evaluate p))
	  (convert-to-boolean (d/evaluate q)))))

(define-method (evaluate node::boolean-and)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::boolean-and node (p q)
      (and (convert-to-boolean (d/evaluate p))
	   (convert-to-boolean (d/evaluate q)))))

(define-method (evaluate node::boolean-xor)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::boolean-xor node (p q)
      (if (convert-to-boolean (d/evaluate p))
	  (if (convert-to-boolean (d/evaluate q))
	      #f
	      #t)
	  (if (convert-to-boolean (d/evaluate q))
	      #t
	      #f))))


(define (evaluate-block block)
   "First declare, then evaluate each statement in a block (list) sequentially,
returning the value of the last. "
   (for-each declare-for-eval block)
   (let ((result '()))
      (dolist (l block)
	 (set! result (d/evaluate l)))
      result))
	 

(define-generic (declare-for-eval node)
   #t)

(define-method (declare-for-eval node::static-decl)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (unless (declared-static-var? node)
      (with-access::static-decl node (var initial-value)
	 (let ((var-name (if (ast-node? var)
			     (mkstr (d/evaluate var))
			     (undollar var))))
	    (widen!::declared-static-var node (name var-name))
	    (env-extend *current-static-env* var-name
			(maybe-box (d/evaluate initial-value)))))))

(define-method (declare-for-eval node::function-decl)
   (set! *PHP-LINE* (car (ast-node-location node)))
   (with-access::function-decl node (location name decl-arglist body ref?)
      (%check-typehints decl-arglist)
      (let ((canonical-name (function-name-canonicalize name)))
	 (widen!::declared-function node (canonical-name canonical-name))
	 (when (get-php-function-sig canonical-name)
	    (php-error/loc node (format "declare-function-decl: Illegal redefinition of function ~A" name)))
	 ;;store signature as a variable arity signature, for func_get_args and friends
	 (store-ast-signature ft-user-interpreted canonical-name #t location decl-arglist)
	 (pushf canonical-name *remove-from-fun-sig-table*)
	 (hashtable-put! *interpreted-function-table* canonical-name
			 (let ((static-env (env-new)))
			    (lambda args
			       (apply push-stack 'unset name args)
			       (push-func-args args)
			       (set! *PHP-LINE* (car location))
			       (set! *PHP-FILE* (cdr location))
			       (let ((retval
				      (bind-exit (return)
					(dynamically-bind (*current-function-name* name)
					 (dynamically-bind (*current-return-escape* return)
 					    (dynamically-bind (*current-static-env* static-env)	   
					       (dynamically-bind (*current-env* (env-new))
						  (dynamically-bind (*current-variable-environment* *current-env*)
						     (add-arguments-to-env name *current-env* args decl-arglist)
						     (d/evaluate body)
						  NULL))))))))
				  (pop-func-args)
				  (pop-stack)
				  (if (and ref? (not (php-null? retval)))
                                      (container->reference! retval)
				      (copy-php-data retval)))))))))



(define-method (declare-for-eval node::class-decl)
   ; essentially, declare all classes whose parent has already been declared (or has none)
   ; the rest we do at runtime
   (letrec ((parents-declared? (lambda (p)
				  (let loop ((l p))
				     (if (null? l)
					 #t
					 (if (hashtable-get *class-decl-table-for-eval* (car l))
					     (loop (cdr l))
					     #f))))))
      (when (or (null? (class-decl-parent-list node))
		(parents-declared? (class-decl-parent-list node)))
	 (%do-class-declare node)
	 (hashtable-put! *class-decl-table-for-eval* (class-decl-name node) #t))))
   
(define (%do-class-declare node::class-decl)
   (with-access::class-decl node (name parent-list implements flags class-body)
      (letrec ((declare-class-body
		(lambda (p)
		      (cond
			 ;; statements
			 ((list? p)
			  (for-each declare-class-body p))
			 ;; class constants			 
			 ((class-constant-decl? p)
			  (define-class-constant name (mkstr (class-constant-decl-name p)) (d/evaluate (class-constant-decl-value p))))
			 ;; properties
			 ((property-decl? p)
			  (define-php-property
			     name
			     (mkstr (undollar (property-decl-name p)))
			     (if (null? (property-decl-value p))
				 (make-container '())
				 (d/evaluate (property-decl-value p)))
			     (property-decl-visibility p)
			     (property-decl-static? p)))
			 ;; methods
			 ((method-decl? p)
			  (with-access::method-decl p (location decl-arglist body ref? flags)
			     (dynamically-bind (*PHP-FILE* (cdr location))
			       (dynamically-bind (*PHP-LINE* (car location))					
				 (%check-typehints decl-arglist)))
			             (define-php-method name
					(mkstr (method-decl-name p))
					flags
					(if (eqv? 'abstract-no-proc body)
					    body
					    ; generate body
					    (let ((static-env (env-new)))
					       (lambda ($this . args)
						  (apply push-stack name (method-decl-name p) args)
						  (push-func-args args)
						  (set! *PHP-FILE* (cdr location))
						  (set! *PHP-LINE* (car location))
						  (let ((retval
							 (bind-exit (return)
					   (dynamically-bind (*current-method-name*
							       (mkstr name "::" (method-decl-name p)))
					    (dynamically-bind (*current-function-name* (method-decl-name p))
					     (dynamically-bind (*current-return-escape* return)
					      (dynamically-bind (*current-static-env* static-env)
					       (dynamically-bind (*current-class-name* name)
 					        (dynamically-bind (*current-parent-class-name* (if (null? parent-list)
												   '()
												   (car parent-list)))
						 (dynamically-bind (*current-instance* $this)
						  (dynamically-bind (*current-env* (env-new))
						   (dynamically-bind (*current-variable-environment* *current-env*)
						     (env-extend *current-env* (undollar '$this) (make-container $this))
						     (add-arguments-to-env (mkstr name "::" (method-decl-name p))
									   *current-env* args decl-arglist)
						     (d/evaluate body)
						     (make-container NULL)))))))))))))
						     (pop-func-args)
						     (pop-stack)
						     (if ref?
							 (container->reference! retval)
							 (copy-php-data retval)))))))))
			  ((nop? p) #t)
			  (else (error 'declare-class "what's this noise doing in my class-decl?" p))))))
	 ;; define class
	 (if (member 'pcc-builtin flags)
	     (define-builtin-php-class name parent-list implements flags)
	     (define-php-class name parent-list implements flags))
	 ;; define body statements
	 (dynamically-bind (*current-class-name* name)
	   (dynamically-bind (*current-parent-class-name* (if (null? parent-list) '() (car parent-list)))
	      (declare-class-body class-body)))
	 ;; finalize
	 (php-class-def-finalize name))))

