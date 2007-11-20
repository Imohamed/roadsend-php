;; ***** BEGIN LICENSE BLOCK *****
;; Roadsend PHP Compiler Runtime Libraries
;; Copyright (C) 2007 Roadsend, Inc.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public License
;; as published by the Free Software Foundation; either version 2.1
;; of the License, or (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.
;; 
;; You should have received a copy of the GNU Lesser General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA
;; ***** END LICENSE BLOCK *****

(module php-object
   (include "php-runtime.sch")
   (import (php-runtime "php-runtime.scm")
	   (elong-lib "elongs.scm")
	   (grass "grasstable.scm")
	   (php-hash "php-hash.scm")
	   (utils "utils.scm")
	   (signatures "signatures.scm")	   
	   (php-errors "php-errors.scm"))
   ; for pcc scheme repl
   (eval (export-module))
   (export
    +constructor-failed+
    ; definitions
    (define-php-class name parent-name flags)
    (define-extended-php-class name parent-name flags getter setter copier)
    (define-php-property class-name property-name value visibility static?)
    (define-php-method class-name method-name flags method)
    ; types
    (convert-to-object doohickey)
    (clone-php-object obj::struct)
    (copy-php-object obj::struct old-new)
    ; reflection
    (php-object-props obj)
    (php-class-methods class-name)
    (php-object-class obj)
    (php-object-parent-class obj)
    (php-class-parent-class class-name)
    (php-object-id obj)
    (get-declared-php-classes)
    ; tests
    (php-object? obj)
    (php-class-exists? class-name)
    (php-class-method-exists? class-name method-name)
    (php-object-is-subclass obj class-name)
    (php-class-is-subclass subclass superclass)
    (php-object-is-a obj class-name)
    (php-object-compare obj1 obj2 identical?)
    (internal-object-compare o1 o2 identical? seen)    
    ; properties
    (php-class-props class-name)
    (php-object-property/index obj::struct property::int property-name)
    (php-object-property/string obj property::bstring access-type)
    (php-object-property-ref/string obj property::bstring access-type)
    (php-object-property-set!/string obj property::bstring value access-type)
    (php-object-property-h-j-f-r/string obj property::bstring access-type)
    (php-object-property obj property access-type)
    (php-object-property-ref obj property access-type)
    (php-object-property-set! obj property value access-type)
    (php-class-static-property class-name property access-type)
    (php-class-static-property-ref class-name property access-type)    
    (php-class-static-property-set! class-name property value access-type)
    (php-object-property-honestly-just-for-reading obj property access-type)
    ; visibility
    (php-object-property-visibility obj prop caller)
    (php-class-static-property-visibility class prop context)
    ; methods
    (make-php-object properties)
    (construct-php-object class-name . args)
    (construct-php-object-sans-constructor class-name)
    (call-php-method obj method-name . call-args)
    (call-php-method-0 obj method-name)
    (call-php-method-1 obj method-name arg)
    (call-php-method-2 obj method-name arg1 arg2)
    (call-php-method-3 obj method-name arg1 arg2 arg3)
    (call-php-parent-method parent-class-name obj method-name . call-args)
    (call-static-php-method class-name obj method-name . call-args)
    ; constants
    (define-class-constant class-name constant-name value)
    (lookup-class-constant class-name constant-name)    
    ; custom properties
    (php-object-custom-properties obj)
    (php-object-custom-properties-set! obj props)
    ; misc
    (init-php-object-lib)
    (pretty-print-php-object obj)
    (php-object-for-each-with-ref-status obj::struct thunk::procedure)
    ;
    ))

;;;;objects, woohoo!
(define-struct %php-object
   ;;instantiation id
   id
   ;;class is a pointer to the class of this object
   class
   ;;properties is a vector of properties. it starts as a copy of
   ;;the defaults from php-class properties vector
   properties
   ;;extended properties is either #f or a php-hash of additional properties
   extended-properties
   ;;this is where custom properties can be stored, for example
   custom-properties)

(define-struct %php-class
   ;;print-name is the class name as the user wrote it (case sensitive)
   print-name
   ;;the canonical name of this class
   name
   ;;a pointer to the parent class of this class
   parent-class
   ;; class flags: abstract, final
   flags
   ;; the constructor method if available
   constructor-proc
   ;; the destructor method if available   
   destructor-proc
   ;;a hashtable mapping names of declared properties to an index in a property vector
   declared-property-offsets
   ;; static properties: like declared-property-offsets, a hash table with index to properties
   static-property-offsets   
   ;;properties is a vector of all properties (which points to actual php data)
   ;;the values here are declared defaults, unless it's static in which case it's the
   ;;actual current value
   properties
   ;;hash of property visibility (protected and private only).
   ;;note: also stores static property visibility
   prop-visibility
   ;;extended properties is either #f or a php-hash of non-declared properties
   extended-properties
   ;;methods is a php-hash of methods, keyed by canonical method name, value is %php-method
   methods
   ;;this overrides the normal property lookup
   custom-prop-lookup
   ;;this overrides the normal property set
   custom-prop-set
   ;;the copier for the custom properties
   custom-prop-copy
   ;; PHP5 "class constants" (php-hash)
   class-constants)

(define-struct %php-method
   ;; print name (case sensitive)
   print-name
   ;; flags: visibility, static, final, abstract
   flags
   ;; procedure
   proc)

;
; PHP5 case sensitivity:
;  - class names are NOT case sensitive
;  - method names are NOT case sensitive
;  - properties ARE case sensitive
; 
; regardless of whether it is case sensitive, each item must
; know the case it was defined as, because it's shown that way
; by various reporting functions
;

(define (php-object-custom-properties obj)
   "returns whatever the custom context was set to when defining the extended class"
   (%php-object-custom-properties obj))

(define (php-object-custom-properties-set! obj props)
   "returns whatever the custom context was set to when defining the extended class"
   (%php-object-custom-properties-set! obj props))

(define (copy-properties-vector old-properties)
   (let* ((properties-len (vector-length old-properties))
	  (new-properties (make-vector properties-len '())))
      (let loop ((i 0))
	 (when (< i properties-len)
	    (let ((old-prop (vector-ref old-properties i)))
	       (if (container-reference? old-prop)
		   (vector-set! new-properties i old-prop)
		   (vector-set! new-properties i
				(copy-php-data old-prop))))
	    (loop (+ i 1))))
      new-properties))

; shallow copy. call __clone on new object if it exists
(define (clone-php-object obj::struct)
   (let ((new-obj (copy-php-object obj #f)))
      (when (php-class-method-exists? (php-object-class obj) "__clone")
	 (call-php-method-0 new-obj "__clone"))
      new-obj))

(define (copy-php-object obj::struct old-new)
   (let* ((new-obj (%php-object (%next-instantiation-id) (%php-object-class obj) #f #f #f)))
      ;;copy the old declared properties
      (%php-object-properties-set!
       new-obj (copy-properties-vector (%php-object-properties obj)))
      ;;copy the old extended properties, if any
      (when (%php-object-extended-properties obj)
	 (%php-object-extended-properties-set!
	  new-obj
	  (copy-php-hash (%php-object-extended-properties obj) old-new)))
      (when (%php-object-custom-properties obj)
	 (%php-object-custom-properties-set!
	  new-obj
	  (let ((c (%php-class-custom-prop-copy (%php-object-class obj))))
	     (if c
		 (c (%php-object-custom-properties obj))
		 (error 'copy-php-object "no custom copier defined for object with custom properties" obj)))))
      new-obj))


(define (make-php-object properties)
   "Make an instance of an anonymous class with properties but no
methods.  Feed me a php-hash where the keys are the properties and the
values the values."
   (let ((new-object (construct-php-object 'stdclass)))
      (unless (php-hash? properties)
	 (error 'make-php-object "properties must be a php-hash" properties))
      (%php-object-extended-properties-set! new-object properties)
      new-object))

;for type coercion 
(define (convert-to-object doohickey)
   (when (container? doohickey)
      (set! doohickey (container-value doohickey)))
   (cond
      ((php-object? doohickey) doohickey)
      ((php-null? doohickey) (make-php-object (make-php-hash)))
      ((php-hash? doohickey) (make-php-object doohickey))
      (else
       (make-php-object (let ((props (make-php-hash)))
 			   (php-hash-insert! props "scalar" doohickey)
 			   props)))))
	  

(define (php-object-props obj)
   "return a php-hash of the keys and properties in an object"
   (if (not (php-object? obj))
       #f
       (let ((property-hash (make-php-hash))
	     (offsets-table (%php-class-declared-property-offsets
					(%php-object-class obj)))
	     (declared-props (%php-object-properties obj)))
	  ;;first copy in the declared properties. we loop over the vector instead
	  ;;of for-each'ing over the hashtable to preserve the ordering.
	  (let loop ((i 0))
	     (when (< i (vector-length declared-props))
		(let ((prop-value (vector-ref declared-props i))
		      (prop-key (hashtable-get offsets-table i)))
		   ; if it's not in offsets table, it's a static and we skip it
		   (when prop-key
		      (php-hash-insert! property-hash
					prop-key
					(if (container-reference? prop-value)
					    prop-value
					    (container-value prop-value)))
		      (loop (+fx i 1))))))
	  ;;now copy in the extended properties
	  (php-hash-for-each (%php-object-extended-properties obj)
	     (lambda (k v)
		(php-hash-insert! property-hash k v)))
	  property-hash)))

(define (php-object-for-each-with-ref-status obj::struct thunk::procedure)
   "Thunk will be called once on each key/value set. ref status is available to thunk"
   (let ((property-hash (make-php-hash))
	 (offsets-table (%php-class-declared-property-offsets
			 (%php-object-class obj)))
	 (declared-props (%php-object-properties obj)))
      (let loop ((i 0))
	 (when (< i (vector-length declared-props))
	    (let ((prop-value (vector-ref declared-props i))
		  (prop-key (hashtable-get offsets-table i)))
;  	       (fprint (current-error-port) "key is " (mkstr (hashtable-get offsets-table i)))
;  	       (fprint (current-error-port) "value is " (mkstr prop-value))
;  	       (fprint (current-error-port) "ref-status is " (mkstr (container-reference? prop-value)))
	       ; if we don't have prop key, it's a static and we skip it
	       (when prop-key
		  (thunk ;note the reverse lookup to get the name
		   (mkstr prop-key)
		   ;		(if (container-reference? prop-value)
		   (maybe-unbox prop-value)
		   ;		    (container-value prop-value))
		   (container-reference? prop-value))
		  (loop (+fx i 1))))))
      ;;now copy in the extended properties
      (php-hash-for-each-with-ref-status
       (%php-object-extended-properties obj) thunk)))

(define (php-class-props class-name)
   "return a php-hash of the keys and properties in a class"
   (let ((the-class (%lookup-class class-name)))
      (if (not (%php-class? the-class))
	  #f
	  (let ((property-hash (make-php-hash))
		(offsets-table (%php-class-declared-property-offsets the-class))
		(declared-props (%php-class-properties the-class)))
	     ;;first copy in the declared properties. we loop over the vector instead
	     ;;of for-each'ing over the hashtable to preserve the ordering.
	     (let loop ((i 0))
		(when (< i (vector-length declared-props))
		   (let ((prop-value (vector-ref declared-props i))
			 (prop-key (hashtable-get offsets-table i)))
		      ; if it's not in offsets table, it's a static and we skip it
		      (when prop-key
			 (php-hash-insert! property-hash
					   ;note the reverse lookup to get the name
					   prop-key
					   (if (container-reference? prop-value)
					       prop-value
					       (container-value prop-value))))
		      (loop (+fx i 1)))))
	     ;;now copy in the extended properties
	     (php-hash-for-each (%php-class-extended-properties the-class)
		(lambda (k v)
		   (php-hash-insert! property-hash k v)))
	     property-hash))))

(define (php-object-is-subclass obj class-name)
   (if (not (php-object? obj))
       #f
       (let ((the-class (%lookup-class class-name)))
	  (if (not (%php-class? the-class))
	      #f
	      (%subclass? (%php-object-class obj) the-class)))))

(define (php-class-is-subclass subclass superclass)
   (let ((the-subclass (%lookup-class subclass))
	 (the-superclass (%lookup-class superclass)))
;      (unless (%php-class? the-subclass)
;	 (debug-trace 1 "warning, class " subclass " not defined"))
;      (unless (%php-class? the-superclass)
;	 (debug-trace 1 "warning, class " superclass " not defined"))
      (and (%php-class? the-subclass)
	   (%php-class? the-superclass)
	   (%subclass? the-subclass the-superclass))))

(define (php-object-is-a obj class-name)
   (if (not (php-object? obj))
       (begin
	  (debug-trace 4 "php-object-is-a: not an object")
	  #f)
       (let ((the-class (%lookup-class class-name)))
	  (if (not (%php-class? the-class))
	      (begin
		 (debug-trace 4 "php-object-is-a: not a class")
		 #f)
	      (or (eqv? (%php-object-class obj) the-class)
		  (begin
		     (debug-trace 4 "php-object-is-a: not eqv?")
		     #f)
		  (%subclass? (%php-object-class obj) the-class)
		  (begin
		     (debug-trace 4 "php-object-is-a: not subclass")
		     #f))))))

(define (php-class-exists? class-name)
   (let ((c (%lookup-class-with-autoload class-name)))
      (if (%php-class? c)
	  #t
	  #f)))

(define (php-class-methods class-name)
   (let ((the-class (%lookup-class class-name)))
      (if (not the-class)
	  #f
	  (%php-class-method-reflection the-class))))

(define (php-class-method-exists? class-name method-name)
   (let ((mlist (php-class-methods class-name)))
      (if mlist ;is this test REALLY necessary?
;	  (php-hash-in-array? mlist (string-downcase (mkstr method-name)) #f)
          (php-hash-in-array? mlist (mkstr method-name) #f)
	  #f)))

(define (method-minimum-arity method)
   ;;one less than the procedure arity, since the first argument is $this
   (-fx (let ((c (procedure-arity method)))
	   (if (<fx c 0)
	       (-fx (- c) 1)
	       c))
	1))

(define (method-correct-arity? method::procedure arity::int)
   (correct-arity? method (+ 1 arity)))

(define (call-php-method obj method-name . call-args)
   (if (not (php-object? obj))
       (php-error "Unable to call method on non-object " obj)
       (let ((the-method (%lookup-method-proc (%php-object-class obj) method-name)))
	  (unless the-method
	     (php-error "Calling method "
			(%php-class-print-name (%php-object-class obj))
			"->" method-name ": undefined method."))
	  ;; We could just apply the method to (map maybe-box call-args), but
	  ;; that won't signal a nice error for methods compiled in extensions.
          (apply the-method obj (adjust-argument-list the-method call-args)))))

(define (adjust-argument-list method args)
   ;; make sure the arguments are boxed and that the arity is okay.
   (if (method-correct-arity? method (length args))
       (map maybe-box args)
       (let ((minimum-arity (method-minimum-arity method)))
          (let loop ((i 0)
                     (new-args '())
                     (args args))
             (if (= i minimum-arity)
                 (reverse! new-args)
                 (if (pair? args)
                     (loop (+ i 1)
                           (cons (maybe-box (car args)) new-args)
                           (cdr args))
                     (loop (+ i 1)
                           (cons (make-container NULL) new-args)
                           '())))))))

(define (call-php-method-0 obj method-name)
   (if (not (php-object? obj))
       (php-error
	(format "Unable to call method on non-object ~A" (mkstr obj)))
       (let ((the-method (%lookup-method-proc (%php-object-class obj) method-name)))
	  (unless the-method
	     (php-error "Calling method "
			(%php-class-print-name (%php-object-class obj))
			"->" method-name ": undefined method."))
	  (the-method obj))))

(define (call-php-method-1 obj method-name arg)
   (if (not (php-object? obj))
       (php-error
	(format "Unable to call method on non-object ~A" (mkstr obj)))
       (let ((the-method (%lookup-method-proc (%php-object-class obj) method-name)))
	  (unless the-method
	     (php-error "Calling method "
			(%php-class-print-name (%php-object-class obj))
			"->" method-name ": undefined method."))
	  (the-method obj (maybe-box arg))) ))

(define (call-php-method-2 obj method-name arg1 arg2)
   (if (not (php-object? obj))
       (php-error
	(format "Unable to call method on non-object ~A" (mkstr obj)))
       (let ((the-method (%lookup-method-proc (%php-object-class obj) method-name)))
	  (unless the-method
	     (php-error "Calling method "
			(%php-class-print-name (%php-object-class obj))
			"->" method-name ": undefined method."))
	  (the-method obj (maybe-box arg1) (maybe-box arg2))) ))

(define (call-php-method-3 obj method-name arg1 arg2 arg3)
   (if (not (php-object? obj))
       (php-error
	(format "Unable to call method on non-object ~A" (mkstr obj)))
       (let ((the-method (%lookup-method-proc (%php-object-class obj) method-name)))
	  (unless the-method
	     (php-error "Calling method "
			(%php-class-print-name (%php-object-class obj))
			"->" method-name ": undefined method."))
	  (the-method obj (maybe-box arg1) (maybe-box arg2) (maybe-box arg3))) ))

(define (call-php-parent-method parent-class-name obj method-name . call-args)
   (let ((the-class (%lookup-class parent-class-name)))
      (unless the-class
	 (php-error
	  (format "Parent method call: Unable to call method parent::~A: can't find parent class ~A"
		  method-name parent-class-name)))
      (let ((the-method (%lookup-method-proc the-class method-name)))
	 (unless the-method
	    (php-error "Parent method call: Unable to find method "
		     method-name " of class " parent-class-name))
	 (apply the-method obj (adjust-argument-list the-method call-args)))))


(define (call-static-php-method class-name obj method-name . call-args)
   (let ((the-class (%lookup-class-with-autoload class-name)))
      (unless the-class
	 (php-error "Calling static method " method-name
		    ": unable to find class definition " class-name))
      (let ((the-method (%lookup-method-proc the-class method-name)))
	 (unless the-method
	    (php-error "Calling static method " class-name "::" method-name ": undefined method."))
	 ;
	 ;
	 ; XXX FIXME: PHP5 does not allow calling a method statically if it was not defined that way
	 ;            check that here and throw a fatal
	 ;
         (apply the-method obj (adjust-argument-list the-method call-args)))))


(define (php-object? obj)
   (%php-object? obj))

(define (php-class? obj)
   (%php-class? obj))

(define (get-custom-lookup obj)
   (%php-class-custom-prop-lookup
    (%php-object-class obj)))

(define (get-custom-set obj)
   (%php-class-custom-prop-set
    (%php-object-class obj)))

(define (php-object-property/index obj::struct property::int property-name)
   "this is just for declared classes in user code.  it's an optimization."
   (assert (property property-name) (= (hashtable-get (%php-class-declared-property-offsets (%php-object-class obj))
						      (%property-name-canonicalize property-name))
				       property))
   (vector-ref (%php-object-properties obj) property)
   
   )


(define (php-object-property obj property access-type)
   (if (php-object? obj)
       (if (procedure? (get-custom-lookup obj))
	   (do-custom-lookup obj property #f)
	   (%lookup-prop obj property access-type))
       (begin
	  (php-warning "Referencing a property of a non-object")
	  NULL)))

(define (php-object-property-honestly-just-for-reading obj property access-type)
   (if (php-object? obj)
       (let ((l (get-custom-lookup obj)))
	  (if (procedure? l)
	      (do-custom-lookup obj property #f)	      
	      (%lookup-prop-honestly-just-for-reading obj property access-type)))
       (begin
	  (php-warning "Referencing a property of a non-object")
	  NULL)))

(define (php-object-property-ref obj property access-type)
   (if (php-object? obj)
       (let ((l (get-custom-lookup obj)))
	  (if (procedure? l)
	      (do-custom-lookup obj property #t)
	      (%lookup-prop-ref obj property access-type)))
       (begin
	  (php-warning "Referencing a property of a non-object")
	  (make-container NULL))))

(define (php-object-property-set! obj property value access-type)
   (if (php-object? obj)
       (let ((l (get-custom-set obj)))
	  (if (procedure? l)
	      (do-custom-set! obj property value)
	      (%assign-prop obj property value access-type)))
       (begin
	  (php-warning "Assigning to a property of a non-object")
	  NULL))
   value)


(define (do-custom-lookup obj property ref?)
   (debug-trace 4 "custom lookup of " (php-object-class obj) "->" property)
;   (if ref?
       ;; so spake the engine of zend
;       (php-error "Cannot create references to overloaded objects")
       (let loop ((cls (%php-object-class obj)))
	  (let ((lookup (%php-class-custom-prop-lookup cls)))
	     (if (procedure? lookup)
		 (let ((val (lookup obj property ref? (lambda ()
							 (loop (%php-class-parent-class cls))))))
		    (if ref? (maybe-box val) (maybe-unbox val)))
		 (if ref?
		     (%lookup-prop-ref obj property 'all)
		     (%lookup-prop obj property 'all))))))
;)

(define (do-custom-set! obj property value)
   (let loop ((cls (%php-object-class obj)))
      (let ((set (%php-class-custom-prop-set cls)))
	 (if (procedure? set)
	     (set obj property (container? value) value  (lambda ()
							   (loop (%php-class-parent-class cls))))
	     (%assign-prop obj property value 'public)))))

(define (php-object-compare o1 o2 identical?)
   (internal-object-compare o1 o2 identical? (make-grasstable)))

(define (internal-object-compare o1 o2 identical? seen)
   (let ((compare-declared-properties
	  (lambda (o1 o2 seen)
	     (let loop ((i 0)
		       (continue? #t))
	       (if (>= i (vector-length (%php-object-properties o1)))
		   #t
		   (if continue?
		       (loop (+ i 1)
			     (let ((o1-value (vector-ref (%php-object-properties o1) i))
				   (o2-value (vector-ref (%php-object-properties o2) i)))
				(cond
				   ((and (php-object? o1-value)
					 (php-object? o2-value))
				    (if (and (grasstable-get o1-value seen)
					     (grasstable-get o2-value seen))
                                        #t
					(internal-object-compare o1-value o2-value identical? seen)))
				   ((and (php-hash? o1-value)
					 (php-hash? o2-value))
				    (if (and (grasstable-get o1-value seen)
					     (grasstable-get o2-value seen))
                                        #t
                                        (zero? (internal-hash-compare o1-value o2-value identical? seen))))
				   (else
				    ((if identical? identicalp equalp) o1-value o2-value)))))
		       #f)))))
	 ;;differently ordered properties in objects mean that they are not ===,
	 ;;but since the objects have to be of the same class to be compared,
	 ;;and the same class naturally declares its properties in the same
	 ;;order, that can only happen in the extended properties.
	 ;;internal-hash-compare will handle it properly, so we don't need to
	 ;;explicitly property order at all.
	 (compare-extended-properties
	  (lambda (o1 o2 seen)
	     (if (%php-object-extended-properties o1)
		(if (%php-object-extended-properties o2)
                    (let ((value (zero? (internal-hash-compare (%php-object-extended-properties o1)
                                                               (%php-object-extended-properties o2)
                                                               identical? seen))))
                       value)
		    #f)
		(if (%php-object-extended-properties o2)
		    #f
		    #t)))))
      ;;the return value is #f if the objects are of different classes
      ;;0 if they are identical, 1 if they are different (but of the same class)
      (if (not (string=? (php-object-class o1)
			 (php-object-class o2)))
	  #f
	  ;only compare objects of the same class
	  (begin
	     (grasstable-put! seen o1 #t)
	     (grasstable-put! seen o2 #t)
	     (if (and (compare-declared-properties o1 o2 seen)
		      (compare-extended-properties o1 o2 seen))
		 0
		 1)))))

(define (php-object-id obj)
   (if (not (php-object? obj))
       #f
       (%php-object-id obj)))
   
(define (php-object-class obj)
   (if (not (php-object? obj))
       #f
       (%php-class-print-name (%php-object-class obj))))

(define (php-object-parent-class obj)
   (if (not (php-object? obj))
       #f
       (%php-class-print-name
	(%php-class-parent-class
	 (%php-object-class obj)))))

(define (php-class-parent-class class-name)
   (let ((the-class (%lookup-class class-name)))
      (if (not (php-class? the-class))
          #f
	  (let ((parent-class (%php-class-parent-class the-class)))
	     (if parent-class
		 (if (string-ci=? (%php-class-print-name parent-class) "stdclass")
		     #f
		     (%php-class-print-name (%php-class-parent-class the-class)))
		 #f)))))


; case insensitive
(define (%class-name-canonicalize name)
   "define class names as case-insensitive strings"
   (string-downcase (mkstr name)))

; case insensitive
(define (%method-name-canonicalize name)
   "define method names as case-insensitive strings"
   (string-downcase (mkstr name)))

; always case sensitive
(define (%property-name-canonicalize name)
   "define property names as case-_sensitive_ strings"
   (if (string? name) name (mkstr name)))

(define %php-class-registry 'unset)
(define %php-autoload-registry 'unset)

(define (get-declared-php-classes)
   (let ((clist (make-php-hash)))
      (hashtable-for-each %php-class-registry
			  (lambda (k v)
			     (php-hash-insert! clist :next (%php-class-print-name v))))
      clist))

(define (init-php-object-lib)
   (set! %php-class-registry (make-hashtable))
   (set! %php-autoload-registry (make-hashtable))
   ;define the root of the class hierarchy
   (let ((stdclass (%php-class "stdClass"       ; print name
			       "stdclass"       ; canonical name
			       #f               ; parent class
			       '()              ; flags
			       #f               ; constructor proc
			       #f               ; destructor proc
			       (make-hashtable) ; declared prop offsets
			       (make-hashtable) ; static prop offets
			       (make-vector 0)  ; props
			       (make-hashtable) ; prop visibility
			       (make-php-hash)  ; extended properties
			       (make-php-hash)  ; methods
			       #f               ; custom prop lookup
			       #f               ; custom prop set
			       #f               ; custom prop copy
			       (make-php-hash)  ; class constants
			       ))
	 (inc-class (%php-class "__PHP_Incomplete_Class"       ; print name
			       "__php_incomplete_class"       ; canonical name
			       #f               ; parent class
			       '()              ; flags
			       #f               ; constructor proc
			       #f               ; destructor proc
			       (make-hashtable) ; declared prop offsets
			       (make-hashtable) ; static prop offets
			       (make-vector 0)  ; props
			       (make-hashtable) ; prop visibility
			       (make-php-hash)  ; extended properties
			       (make-php-hash)  ; methods
			       #f               ; custom prop lookup
			       #f               ; custom prop set
			       #f               ; custom prop copy
			       (make-php-hash)  ; class constants
			       )))
      ;;default constructor
      (hashtable-put! %php-class-registry "stdclass" stdclass)
      (hashtable-put! %php-class-registry "__php_incomplete_class" inc-class)))

(define (define-php-class name parent-name flags)
   (if (%lookup-class name)
       #t ;leave the errors to the evaluator/compiler for now
       (let ((parent-class (if (null? parent-name)
			       (%lookup-class "stdclass")
			       (%lookup-class-with-autoload parent-name))))
	  (unless parent-class
	     (php-error "Defining class " name ": unable to find parent class " parent-name))
	  (let* ((canonical-name (%class-name-canonicalize name))
		 (new-class (%php-class (mkstr name)
					canonical-name
					parent-class
					flags
                                        #f
					#f
					(copy-hashtable
					 (%php-class-declared-property-offsets parent-class))
					(copy-hashtable
					 (%php-class-static-property-offsets parent-class))					
					(copy-properties-vector (%php-class-properties parent-class))
					(copy-prop-visibility
					 (%php-class-prop-visibility parent-class))				 
					(copy-php-data (%php-class-extended-properties parent-class))
					(copy-php-data (%php-class-methods parent-class))
					(%php-class-custom-prop-lookup parent-class)
					(%php-class-custom-prop-set parent-class)
					(%php-class-custom-prop-copy parent-class)
                                        (copy-php-data (%php-class-class-constants parent-class))
					)))
	     (hashtable-put! %php-class-registry canonical-name new-class)))))

(define (define-extended-php-class name parent-name flags getter setter copier)
   "Create a PHP class with an overridden getter and setter.  The getter takes
four arguments: the object, the property, ref?, and the continuation.  The
continuation is a procedure of no arguments that can be invoked to get the
default property lookup behavior.  The setter takes an additional value
argument, before the continuation: (obj prop ref? value k)."
   ;xxx and a copier, and they can be false to inherit...
   (define-php-class name parent-name flags)
   (let ((klass (%lookup-class name)))
      (if (%php-class? klass)
	  (begin
	     (when getter (%php-class-custom-prop-lookup-set! klass getter))
	     (when setter (%php-class-custom-prop-set-set! klass setter))
	     (when copier (%php-class-custom-prop-copy-set! klass copier))
	     ;we set the print-name to be like php-gtk with its CamelCaps
	     (%php-class-print-name-set! klass name))
	  (error 'define-extended-php-class "could not define extended class" name))))

(define (copy-prop-visibility table)
   (let ((new-table (make-hashtable)))
      (hashtable-for-each table
	 (lambda (k v)
	    (unless (eqv? v 'private)
	       (hashtable-put! new-table k v))))
      new-table))

(define (copy-hashtable table)
   (let ((new-table (make-hashtable)))
      (hashtable-for-each table
	 (lambda (k v)
	    (hashtable-put! new-table k v)))
      new-table))

; XXX use copy-vector?
(define (cruddy-push-extend el vec)   
   ;yay, quadratic
   (let ((new (make-vector (+ 1 (vector-length vec)) '())))
      (let loop ((i 0))
	 (if (< i (vector-length vec))
	     (begin
		(vector-set! new i (vector-ref vec i))
		(loop (+ i 1)))
	     (vector-set! new i el)))
      new))

(define (define-php-method class-name method-name flags method)
   (let ((the-class (%lookup-class class-name)))
      (unless the-class
	 (php-error "Defining method " method-name ": unknown class " class-name))
      (let* ((canon-method-name (%method-name-canonicalize method-name))
	     (new-method (%php-method method-name flags method)))
         ;; check if the method is a constructor
	 (when (or (string=? canon-method-name "__construct")
		   (and (not (%php-class-constructor-proc the-class))
			(string=? canon-method-name (%php-class-name the-class))))
	    (%php-class-constructor-proc-set! the-class method))
	 ;; check if the method is a destructor
	 (when (string=? canon-method-name "__destruct")
	    (%php-class-destructor-proc-set! the-class method))
         (php-hash-insert! (%php-class-methods the-class)
                           canon-method-name
                           new-method))))

(define (mangle-property-private prop)
   "mangle given property string to private visibility"
   (mkstr prop ":private"))

(define (mangle-property-protected prop)
   "mangle given property string to protected visibility"
   (mkstr prop ":protected"))

(define (%property-name-mangle name visibility)
   (cond
      ((eqv? 'public visibility)
       name)
      ((eqv? 'private visibility)
       (mangle-property-private name))
      ((eqv? 'protected visibility)
       (mangle-property-protected name))))

(define (define-php-property class-name property-name value visibility static?)
   (let ((the-class (%lookup-class class-name)))
      (unless the-class
	 (php-error "Defining property " property-name ": unknown class " class-name))
      (let* ((properties (%php-class-properties the-class))
	     (offset (vector-length properties))
             (canonical-name (%property-name-canonicalize property-name))
	     (mangled-name (%property-name-mangle canonical-name visibility))
	     (offset-hash (if static?
			      (%php-class-static-property-offsets the-class)
			      (%php-class-declared-property-offsets the-class))))
         (aif (hashtable-get offset-hash mangled-name)
              ;; already defined, just set it
              (vector-set! properties it (make-container (maybe-unbox value)))
              ;; not defined yet, extend the properties vector and add
              ;; a new entry in the offset map
              (begin
                 (%php-class-properties-set!
                  the-class
                  (cruddy-push-extend (make-container (maybe-unbox value)) properties))
                 (hashtable-put! offset-hash
                                 mangled-name
                                 offset)
                 ;store the reverse, too
                 (hashtable-put! offset-hash
                                 offset
                                 mangled-name)
		 ;store visibility
		 (unless (eqv? 'public visibility)
		  (hashtable-put! (%php-class-prop-visibility the-class)
				  canonical-name
				  visibility)))))))


(define (%lookup-class name)
   (hashtable-get %php-class-registry (%class-name-canonicalize name)))

; here we try magic __autoload global function if the class name is
; not found (PHP5 feature)
(define (%lookup-class-with-autoload name)
   (let ((the-class (%lookup-class name)))
      (if the-class
	  the-class
	  ; try autoload
	  (let ((canonical-name (%class-name-canonicalize name))
		(autoload-proc (get-php-function-sig "__autoload")))
	     (if autoload-proc
		 (unless (hashtable-get %php-autoload-registry canonical-name)
		    (hashtable-put! %php-autoload-registry canonical-name #t)
		    (php-funcall "__autoload" (mkstr name))
		    (%lookup-class name))
		 #f)))))

;;I think that all methods must be manifest when a class is defined
;;(i.e. before calling any of them), so we don't look at the parent
;;class.
(define (%lookup-method klass name)
   (let ((m (php-hash-lookup (%php-class-methods klass) name)))
      (if (null? m)
	  (begin
	     ;	     (fprint (current-error-port) "slow path: " name)
	     ;;the slow path -- funky method case, method in superclass, etc
	     (let ((cname (%method-name-canonicalize name)))
		;;first we try looking the method up again, using the canonical name
		(let loop ((super klass))
		   (if (%php-class? super)
		       (let ((m (php-hash-lookup (%php-class-methods super) cname)))
			  (if (null? m)
			      ;;still not found, try the superclass
			      (loop (%php-class-parent-class super))
			      ;;found it.  store it for the next time.
			      (begin
				 (php-hash-insert! (%php-class-methods klass) cname m)
				 m)))
		       ;; there is no parent class, method not found.
		       #f))))
	  m)))

(define (%lookup-method-proc klass name)
   (let ((m (%lookup-method klass name)))
      (if m
	  (%php-method-proc m)
	  #f)))

(define (%lookup-constructor klass)
   (or
    (%php-class-constructor-proc klass)
    (let ((c (and (%php-class-parent-class klass)
                  (%lookup-constructor (%php-class-parent-class klass)))))
       (if c
           (begin
              (%php-class-constructor-proc-set! klass c)
              c)
           #f))))

(define (%lookup-destructor klass)
   (or
    (%php-class-destructor-proc klass)
    (let ((c (and (%php-class-parent-class klass)
                  (%lookup-destructor (%php-class-parent-class klass)))))
       (if c
           (begin
              (%php-class-destructor-proc-set! klass c)
              c)
           #f))))

; decide what kind of visibility caller has to obj->prop
(define (php-object-property-visibility obj prop caller)
   (if (php-object? obj)
       (let ((access-type 'public))
	  (let ((ovis (hashtable-get
		       (%php-class-prop-visibility
			(%php-object-class obj))
		       (%property-name-canonicalize prop))))
	     ; ovis holds the declared visibility of prop. if it's private,
	     ; only allow it if caller is the same class. if it's protected,
	     ; allow it if caller has obj as a decendant
	     (when ovis
		; private
		(when (eqv? ovis 'private)
		   (if (and (php-object? caller)
			    (eqv? (%php-object-class caller)
				  (%php-object-class obj)))
		       (set! access-type 'all)
		       (set! access-type (cons ovis 'none))))
		; protected
		(when (eqv? ovis 'protected)
		   (if (and (php-object? caller)
			    (or (eqv? (%php-object-class caller)
				      (%php-object-class obj))
				(%subclass? (%php-object-class caller)
					    (%php-object-class obj))))
		       (set! access-type 'protected)
		       (set! access-type (cons ovis 'none))))))
	  access-type)
       ; will result in referencing a property of a non object
       'public))

; decide what kind of visibility given static class has to class::prop
(define (php-class-static-property-visibility class-name prop context)
   ; context will be:
   ;  class name - if class-name == context class, allow all. subclass, allow proteced/public, otherwise public only
   ; #f - global context, only public access
   ; class-name should be a currently defined class symbol (with self and parent already processed)
   (if (not (eqv? context #f))
       (let ((the-class (%lookup-class-with-autoload class-name))
	     (context-class (%lookup-class-with-autoload context))
	     (access-type 'public))
	  (unless (and the-class context-class)
	     (php-error "static property check on unknown class or context: " class-name " | " context))
	  (let ((ovis (hashtable-get
		       (%php-class-prop-visibility the-class)
		       (%property-name-canonicalize prop))))
	     ; ovis holds the declared visibility of prop. if it's private,
	     (when ovis
		; private
		(when (eqv? ovis 'private)
		   (if (eqv? context-class
			     the-class)
		       (set! access-type 'all)
		       (set! access-type (cons ovis 'none))))
		; protected
		(when (eqv? ovis 'protected)
		   (if (or (eqv? context-class
				 the-class)
			   (%subclass? context
				       the-class))
		       (set! access-type 'protected)
		       (set! access-type (cons ovis 'none))))))
	  access-type)
       ; unset, global context
       'public))

(define (php-class-static-property class-name property access-type)
   (let ((the-class (%lookup-class-with-autoload class-name)))
      (unless the-class
	 (php-error "Getting static property " property ": unknown class " class-name))
      (let ((val (%lookup-static-prop class-name property access-type)))
	 (if val
	     val
	  (php-error "Access to undeclared static property: " class-name "::" property)))))	     

(define (php-class-static-property-ref class-name property access-type)
   (let ((the-class (%lookup-class-with-autoload class-name)))
      (unless the-class
	 (php-error "Getting static property " property ": unknown class " class-name))
      (let ((val (%lookup-static-prop-ref class-name property access-type)))
	 (if val
	     val
	     (begin
		(php-error "Access to undeclared static property: " class-name "::" property)
		(make-container NULL))))))

(define (php-class-static-property-set! class-name property value access-type)
   (let ((the-class (%lookup-class class-name)))
      (unless the-class
	 (php-error "Setting static property " property ": unknown class " class-name))
      (let* ((canon-name (%property-name-canonicalize property))
	     (offset (%prop-offset the-class canon-name access-type)))
	 (if offset
	     (begin
		(if (container? value)
		    ;reference insert, like for php-hash
		    (vector-set! (%php-class-properties the-class) offset (container->reference! value))
		    (let ((current-value (vector-ref (%php-class-properties the-class) offset)))
		       (if (container? current-value)
			   (container-value-set! current-value value)
			   (vector-set! (%php-class-properties the-class) offset (make-container value)))))
		value)
	     ;undeclared property
	     (php-error "Access to undeclared static property: " class-name "::" property)))))

;; this handles visibility mangling
;; since we use this for statics, it can be called for objects or classes
;; it will check in order: public (no mangle), protected, private
;; based on access-type, which should be either: public, protected, or all
(define (%prop-offset obj-or-class prop-canon-name access-type)
   (let ((prop-hash (cond ((php-object? obj-or-class)
			   (%php-class-declared-property-offsets
			    (%php-object-class obj-or-class)))
			  ((%php-class? obj-or-class)
			   (%php-class-static-property-offsets
			    obj-or-class))
			  (else
			   (error '%prop-offset "not an object or class" obj-or-class)))))
      (let ((prop (hashtable-get
		   prop-hash
		   prop-canon-name)))
	 (if prop
	     ; found a public
	     prop
	     (if (or (eqv? access-type 'protected)
		     (eqv? access-type 'all))
		 (let ((prop (hashtable-get
			      prop-hash
			      (mangle-property-protected prop-canon-name))))
		    (if prop
			; found a protected
			prop
			; either private or nothin'
			(if (eqv? access-type 'all)
			    (hashtable-get
			     prop-hash
			     (mangle-property-private prop-canon-name))
			    ; no visibility
			    #f)))
		 ; no visibility
		 #f)))))
		
;;;;the actual property looker-uppers
(define (%lookup-prop-ref obj property access-type)
   (let* ((canon-name (%property-name-canonicalize property))
	  (offset (%prop-offset obj canon-name access-type)))
      (if offset	  
	  (vector-ref (%php-object-properties obj) offset)
	  (php-hash-lookup-ref (%php-object-extended-properties obj)
			       #t
			       canon-name))))

(define (%lookup-prop obj property access-type)
   (container-value (%lookup-prop-ref obj property access-type)))

(define (%lookup-prop-honestly-just-for-reading obj property access-type)
   (let* ((canon-name (%property-name-canonicalize property))
	  (offset (%prop-offset obj canon-name access-type)))
      (if offset
	  (container-value (vector-ref (%php-object-properties obj) offset))
	  ;XXX this wasn't here.. copying bug?
	  (php-hash-lookup-honestly-just-for-reading
	   (%php-object-extended-properties obj)
	   canon-name) )))


(define (%assign-prop obj property value access-type)
   (let* ((canon-name (%property-name-canonicalize property))
	  (offset (%prop-offset obj canon-name access-type)))
      (if offset
	  ;declared property
	  (if (container? value)
	      ;reference insert, like for php-hash
              (vector-set! (%php-object-properties obj) offset (container->reference! value))
              (let ((current-value (vector-ref (%php-object-properties obj) offset)))
                 (if (container? current-value)
                     (container-value-set! current-value value)
                     (vector-set! (%php-object-properties obj) offset (make-container value)))))
   	  ;undeclared property
          (php-hash-insert! (%php-object-extended-properties obj)
                            canon-name value)))

   value)

(define (%lookup-static-prop-ref class-name property access-type)
   (let ((the-class (%lookup-class class-name)))
      (if the-class   
	  (let* ((canon-name (%property-name-canonicalize property))
		 (offset (%prop-offset the-class canon-name access-type)))
	     (if offset
		 (vector-ref (%php-class-properties the-class) offset)
		 #f))
	  #f)))

(define (%lookup-static-prop class-name property access-type)
   (container-value (%lookup-static-prop-ref class-name property access-type)))

(define (%php-class-method-reflection klass)
    (list->php-hash
     (let ((lst '()))
        (php-hash-for-each (%php-class-methods klass)
 	  (lambda (name method)
 	     (set! lst (cons (%php-method-print-name method) lst))))
        lst)))

(define *highest-instantiation* 0)
(define (%next-instantiation-id)
   (set! *highest-instantiation* (+ 1 *highest-instantiation*))
   *highest-instantiation*)

(define +constructor-failed+ (cons '() '()))
(define (construct-php-object class-name . args)
   (let ((the-class (%lookup-class-with-autoload class-name)))
      (unless the-class
	 (php-error "Unable to instantiate " class-name ": undefined class."))
      ;
      ; XXX we're copying all properties here, but we shouldn't be copying static
      ; properties since they will never be accessed from the object vector (they use the
      ; class vector). so, we're wasting some memory      
      (let ((new-object (%php-object (%next-instantiation-id)
			             the-class
				     (copy-properties-vector
				      (%php-class-properties the-class))
				     (copy-php-data
				      (%php-class-extended-properties the-class))
				     #f)))
	 ;; if we have a destructor, make sure the class is finalized
	 (let ((destructor (%lookup-destructor the-class)))
	    (when destructor
	       (register-finalizer! new-object (lambda (obj)
						  (apply destructor obj (adjust-argument-list destructor args))))))
	 ; now run constructor, or return new obj if we have none
	 (let ((constructor (%lookup-constructor the-class)))
	    (if (not constructor)
                ;; no constructor defined
                new-object
		(if (eq? +constructor-failed+
			 (apply constructor new-object (adjust-argument-list constructor args)))
		    (begin
		       (php-warning "Could not create a " class-name " object.")
		       NULL)
		    new-object))))))


(define (construct-php-object-sans-constructor class-name)
   (let ((the-class (%lookup-class-with-autoload class-name)))
      (unless the-class
	 (php-error "Unable to instantiate " class-name ": undefined class."))
      (let ((new-object (%php-object (%next-instantiation-id)
			             the-class
				     ;
				     ; XXX we're copying all properties here, but we shouldn't be copying static
				     ; properties since they will never be accessed from the object vector (they use the
				     ; class vector). so, we're wasting some memory
				     (copy-properties-vector
				      (%php-class-properties the-class))
				     (copy-php-data
				      (%php-class-extended-properties the-class))
				     #f)))
	 new-object)))



(define (%subclass? class-a class-b)
   "is class-a a subclass of class-b?"
   (let ((parent (%php-class-parent-class class-a) ))
      (and parent
	   (or (eqv? parent class-b)
	       (%subclass? parent class-b)))))


;;;string versions, for compiled code
(define (php-object-property/string obj property::bstring access-type)
   (php-object-property obj property access-type))

(define (php-object-property-h-j-f-r/string obj property::bstring access-type)
   (php-object-property-honestly-just-for-reading obj property access-type))

(define (php-object-property-set!/string obj property::bstring value access-type)
   (php-object-property-set! obj property value access-type))

(define (php-object-property-ref/string obj property::bstring access-type)
   (php-object-property-ref obj property access-type))

(define (%lookup-prop-ref/string obj property::bstring access-type)
   (%lookup-prop-ref obj property access-type))

(define (%lookup-prop/string obj property::bstring access-type)
   (%lookup-prop obj property access-type))

(define (%lookup-prop-h-j-f-r/string obj property::bstring access-type)
   (%lookup-prop-honestly-just-for-reading obj property access-type))

(define (%assign-prop/string obj property::bstring value)
   (%assign-prop obj property value 'public))
   
;;;end string versions


(define (pretty-print-php-object obj)
   (display "<php object, class: ")
   (display (%php-class-print-name
	     (%php-object-class obj)))
   (display ", properties: ")
   (php-object-for-each-with-ref-status
    obj
    (lambda (name value ref?)
       (display (mkstr name))
       (display "=>")
       (cond
	  ((php-hash? value)
	   (display "php-hash(")
	   (display (php-hash-size value))
	   (display ")"))
	  ((php-object? value)
	   (display "php-object(")
	   (display (%php-class-print-name
		     (%php-object-class obj)))
	   (display ")"))
	  (else (display (mkstr value))))
       (display " ")))
   (display ">"))


;;;; PHP5 "class constants".
(define (define-class-constant class-name constant-name value)
   (let ((the-class (%lookup-class class-name)))
      (unless the-class
         (php-error "Defining class constant " constant-name ": unknown class " class-name))
      (php-hash-insert! (%php-class-class-constants the-class) constant-name value)))

(define (lookup-class-constant class-name constant-name)
   (let ((fail (lambda ()
                  (php-error "Access to undeclared class constant: "
                             class-name "::"  constant-name))))
      (let* ((the-class (%lookup-class class-name)))
         (unless the-class (fail))
         (unless (php-hash-contains? (%php-class-class-constants the-class)
                                     constant-name)
            (fail))
         (php-hash-lookup (%php-class-class-constants the-class)
                          constant-name))))

   
