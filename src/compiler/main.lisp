;;;; the top level interfaces to the compiler, plus some other
;;;; compiler-related stuff (e.g. CL:CALL-ARGUMENTS-LIMIT) which
;;;; doesn't obviously belong anywhere else

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-C")

(defvar *block-compile-default* nil
  "The default value for the :Block-Compile argument to COMPILE-FILE.")

(defvar *entry-points-argument*)
(declaim (type list *entry-points-argument*))

(defvar *check-consistency* nil)

;;; Set to NIL to disable loop analysis for register allocation.
(defvar *loop-analyze* t)

(defvar *compile-verbose* t
  "The default for the :VERBOSE argument to COMPILE-FILE.")
(defvar *compile-print* nil
  "The default for the :PRINT argument to COMPILE-FILE.")
(defvar *compile-progress* nil
  "When this is true, the compiler prints to *STANDARD-OUTPUT* progress
  information about the phases of compilation of each function. (This
  is useful mainly in large block compilations.)")

(defvar *compile-file-pathname* nil
  "The defaulted pathname of the file currently being compiled, or NIL if not
  compiling.")
(defvar *compile-file-truename* nil
  "The TRUENAME of the file currently being compiled, or NIL if not
  compiling.")

(declaim (type (or pathname null)
               *compile-file-pathname*
               *compile-file-truename*))

;;; the SOURCE-INFO structure for the current compilation. This is
;;; null globally to indicate that we aren't currently in any
;;; identifiable compilation.
(defvar *source-info* nil)

;;; This is true if we are within a WITH-COMPILATION-UNIT form (which
;;; normally causes nested uses to be no-ops).
(defvar *in-compilation-unit* nil)

;;; Count of the number of compilation units dynamically enclosed by
;;; the current active WITH-COMPILATION-UNIT that were unwound out of.
(defvar *aborted-compilation-unit-count*)

;;; Mumble conditional on *COMPILE-PROGRESS*.
(defun maybe-mumble (&rest foo)
  (when *compile-progress*
    (apply #'compiler-mumble foo)))


(deftype object () '(or fasl-output core-object null))
(declaim (type object *compile-object*))

(defvar *emit-cfasl* nil)

(defvar *fopcompile-label-counter*)

(declaim (inline code-coverage-records code-coverage-blocks))
;; Used during compilation to map code paths to the matching
;; instrumentation conses.
(defun code-coverage-records (x) (car x))
;; Used during compilation to keep track of with source paths have been
;; instrumented in which blocks.
(defun code-coverage-blocks (x) (cdr x))

;;;; WITH-COMPILATION-UNIT and WITH-COMPILATION-VALUES

(defmacro with-compilation-unit (options &body body)
  "Affects compilations that take place within its dynamic extent. It is
intended to be eg. wrapped around the compilation of all files in the same system.

Following options are defined:

  :OVERRIDE Boolean-Form
      One of the effects of this form is to delay undefined warnings until the
      end of the form, instead of giving them at the end of each compilation.
      If OVERRIDE is NIL (the default), then the outermost
      WITH-COMPILATION-UNIT form grabs the undefined warnings. Specifying
      OVERRIDE true causes that form to grab any enclosed warnings, even if it
      is enclosed by another WITH-COMPILATION-UNIT.

  :POLICY Optimize-Declaration-Form
      Provides dynamic scoping for global compiler optimization qualities and
      restrictions, limiting effects of subsequent OPTIMIZE proclamations and
      calls to SB-EXT:RESTRICT-COMPILER-POLICY to the dynamic scope of BODY.

      If OVERRIDE is false, specified POLICY is merged with current global
      policy. If OVERRIDE is true, current global policy, including any
      restrictions, is discarded in favor of the specified POLICY.

      Supplying POLICY NIL is equivalent to the option not being supplied at
      all, ie. dynamic scoping of policy does not take place.

      This option is an SBCL-specific experimental extension: Interface
      subject to change.

  :SOURCE-NAMESTRING Namestring-Form
      Attaches the value returned by the Namestring-Form to the internal
      debug-source information as the namestring of the source file. Normally
      the namestring of the input-file for COMPILE-FILE is used: this option
      can be used to provide source-file information for functions compiled
      using COMPILE, or to override the input-file of COMPILE-FILE.

      If both an outer and an inner WITH-COMPILATION-UNIT provide a
      SOURCE-NAMESTRING, the inner one takes precedence. Unaffected
      by :OVERRIDE.

      This is an SBCL-specific extension.

  :SOURCE-PLIST Plist-Form
      Attaches the value returned by the Plist-Form to internal debug-source
      information of functions compiled in within the dynamic extent of BODY.

      Primarily for use by development environments, in order to eg. associate
      function definitions with editor-buffers. Can be accessed using
      SB-INTROSPECT:DEFINITION-SOURCE-PLIST.

      If an outer WITH-COMPILATION-UNIT form also provide a SOURCE-PLIST, it
      is appended to the end of the provided SOURCE-PLIST. Unaffected
      by :OVERRIDE.

      This is an SBCL-specific extension.

Examples:

  ;; Prevent proclamations from the file leaking, and restrict
  ;; SAFETY to 3 -- otherwise uses the current global policy.
  (with-compilation-unit (:policy '(optimize))
    (restrict-compiler-policy 'safety 3)
    (load \"foo.lisp\"))

  ;; Using default policy instead of the current global one,
  ;; except for DEBUG 3.
  (with-compilation-unit (:policy '(optimize debug)
                          :override t)
    (load \"foo.lisp\"))

  ;; Same as if :POLICY had not been specified at all: SAFETY 3
  ;; proclamation leaks out from WITH-COMPILATION-UNIT.
  (with-compilation-unit (:policy nil)
    (declaim (optimize safety))
    (load \"foo.lisp\"))
"
  `(%with-compilation-unit (lambda () ,@body) ,@options))

(defvar *source-plist* nil)
(defvar *source-namestring* nil)

(defun %with-compilation-unit (fn &key override policy source-plist source-namestring)
  (declare (type function fn))
  (declare (dynamic-extent fn))
  (flet ((with-it ()
           (let ((succeeded-p nil)
                 (*source-plist* (append source-plist *source-plist*))
                 (*source-namestring*
                  (awhen (or source-namestring *source-namestring*)
                    (possibly-base-stringize it))))
             (if (and *in-compilation-unit* (not override))
                 ;; Inside another WITH-COMPILATION-UNIT, a WITH-COMPILATION-UNIT is
                 ;; ordinarily (unless OVERRIDE) basically a no-op.
                 (unwind-protect
                      (multiple-value-prog1 (funcall fn) (setf succeeded-p t))
                   (unless succeeded-p
                     (incf *aborted-compilation-unit-count*)))
                 (let ((*aborted-compilation-unit-count* 0)
                       (*compiler-error-count* 0)
                       (*compiler-warning-count* 0)
                       (*compiler-style-warning-count* 0)
                       (*compiler-note-count* 0)
                       (*undefined-warnings* nil)
                       *argument-mismatch-warnings*
                       *methods-in-compilation-unit*
                       (*in-compilation-unit* t))
                   (handler-bind ((parse-unknown-type
                                    (lambda (c)
                                      (note-undefined-reference
                                       (parse-unknown-type-specifier c)
                                       :type))))
                     (unwind-protect
                          (multiple-value-prog1 (funcall fn) (setf succeeded-p t))
                       (unless succeeded-p
                         (incf *aborted-compilation-unit-count*))
                       (summarize-compilation-unit (not succeeded-p)))))))))
    (if policy
        (let ((*policy* (process-optimize-decl policy (unless override *policy*)))
              (*policy-min* (unless override *policy-min*))
              (*policy-max* (unless override *policy-max*)))
          (with-it))
        (with-it))))

;;; Is NAME something that no conforming program can rely on
;;; defining?
(defun name-reserved-by-ansi-p (name kind)
  (declare (ignorable name kind))
  #-sb-xc-host ; always return NIL in the cross-compiler
  (ecase kind
    (:function
     (eq (sb-xc:symbol-package (fun-name-block-name name))
         *cl-package*))
    (:type
     (let ((symbol (typecase name
                     (symbol name)
                     ((cons symbol) (car name))
                     (t (return-from name-reserved-by-ansi-p nil)))))
       (eq (sb-xc:symbol-package symbol) *cl-package*)))))

;;; This is to be called at the end of a compilation unit. It signals
;;; any residual warnings about unknown stuff, then prints the total
;;; error counts. ABORT-P should be true when the compilation unit was
;;; aborted by throwing out. ABORT-COUNT is the number of dynamically
;;; enclosed nested compilation units that were aborted.
(defun summarize-compilation-unit (abort-p)
  (let (summary)
    (unless abort-p
      (let ((undefs (sort *undefined-warnings* #'string<
                          :key (lambda (x)
                                 (let ((x (undefined-warning-name x)))
                                   (if (symbolp x)
                                       (symbol-name x)
                                       (prin1-to-string x))))))
            (*last-message-count* (list* 0 nil nil))
            (*last-error-context* nil))
        (handler-bind ((style-warning #'compiler-style-warning-handler)
                       (warning #'compiler-warning-handler))
          (report-key-arg-mismatches)
          (dolist (kind '(:variable :function :type))
            (let ((names (mapcar #'undefined-warning-name
                                 (remove kind undefs :test #'neq
                                                     :key #'undefined-warning-kind))))
              (when names (push (cons kind names) summary))))
          (dolist (undef undefs)
            (let ((name (undefined-warning-name undef))
                  (kind (undefined-warning-kind undef))
                  (warnings (undefined-warning-warnings undef))
                  (undefined-warning-count (undefined-warning-count undef)))
              (dolist (*compiler-error-context* warnings)
                (if (and (member kind '(:function :type))
                         (name-reserved-by-ansi-p name kind))
                    (ecase kind
                      (:function
                       (compiler-warn
                        "~@<The function ~S is undefined, and its name is ~
                            reserved by ANSI CL so that even if it were ~
                            defined later, the code doing so would not be ~
                            portable.~:@>" name))
                      (:type
                       (if (and (consp name) (eq 'quote (car name)))
                           (compiler-warn
                            "~@<Undefined type ~S. The name starts with ~S: ~
                             probably use of a quoted type name in a context ~
                             where the name is not evaluated.~:@>"
                            name 'quote)
                           (compiler-warn
                            "~@<Undefined type ~S. Note that name ~S is ~
                             reserved by ANSI CL, so code defining a type with ~
                             that name would not be portable.~:@>" name
                             name))))
                    (funcall
                     (if (eq kind :variable) #'compiler-warn #'compiler-style-warn)
                     (sb-format:tokens "undefined ~(~A~): ~/sb-ext:print-symbol-with-prefix/")
                     kind name)))
              (let ((warn-count (length warnings)))
                (when (and warnings (> undefined-warning-count warn-count))
                  (let ((more (- undefined-warning-count warn-count)))
                    (if (eq kind :variable)
                        (compiler-warn
                         "~W more use~:P of undefined ~(~A~) ~S"
                         more kind name)
                        (compiler-style-warn
                         "~W more use~:P of undefined ~(~A~) ~S"
                         more kind name))))))))))

    (unless (and (not abort-p)
                 (zerop *aborted-compilation-unit-count*)
                 (zerop *compiler-error-count*)
                 (zerop *compiler-warning-count*)
                 (zerop *compiler-style-warning-count*)
                 (zerop *compiler-note-count*))
      (fresh-line *error-output*)
      (pprint-logical-block (*error-output* nil :per-line-prefix "; ")
        (format *error-output* "~&compilation unit ~:[finished~;aborted~]"
                abort-p)
        (dolist (cell summary)
          (destructuring-bind (kind &rest names) cell
            (format *error-output*
                    "~&  Undefined ~(~A~)~p:~
                     ~%    ~{~<~% ~1:;~S~>~^ ~}"
                    kind (length names) names)))
        (format *error-output* "~[~:;~:*~&  caught ~W fatal ERROR condition~:P~]~
                                ~[~:;~:*~&  caught ~W ERROR condition~:P~]~
                                ~[~:;~:*~&  caught ~W WARNING condition~:P~]~
                                ~[~:;~:*~&  caught ~W STYLE-WARNING condition~:P~]~
                                ~[~:;~:*~&  printed ~W note~:P~]"
                *aborted-compilation-unit-count*
                *compiler-error-count*
                *compiler-warning-count*
                *compiler-style-warning-count*
                *compiler-note-count*))
      (terpri *error-output*)
      (force-output *error-output*))))

;;; Evaluate BODY, then return (VALUES BODY-VALUE WARNINGS-P
;;; FAILURE-P), where BODY-VALUE is the first value of the body, and
;;; WARNINGS-P and FAILURE-P are as in CL:COMPILE or CL:COMPILE-FILE.
(defmacro with-compilation-values (&body body)
  `(let ((*finite-sbs*
          (vector
           ,@(loop for sb across *backend-sbs*
                   unless (eq (sb-kind sb) :non-packed)
                   collect
                   (let ((size (sb-size sb)))
                     `(make-finite-sb
                       :conflicts (make-array ,size :initial-element #())
                       :always-live (make-array ,size :initial-element #*)
                       :live-tns (make-array ,size :initial-element nil)))))))
     (let ((*warnings-p* nil)
           (*failure-p* nil))
       (handler-bind ((compiler-error #'compiler-error-handler)
                      (style-warning #'compiler-style-warning-handler)
                      (warning #'compiler-warning-handler))
         (values (progn ,@body) *warnings-p* *failure-p*)))))

;;; THING is a kind of thing about which we'd like to issue a warning,
;;; but showing at most one warning for a given set of <THING,FMT,ARGS>.
;;; The compiler does a good job of making sure not to print repetitive
;;; warnings for code that it compiles, but this solves a different problem.
;;; Specifically, for a warning from PARSE-LAMBDA-LIST, there are three calls:
;;; - once in the expander for defmacro itself, as it calls MAKE-MACRO-LAMBDA
;;;   which calls PARSE-LAMBDA-LIST. This is the toplevel form processing.
;;; - again for :compile-toplevel, where the DS-BIND calls PARSE-LAMBDA-LIST.
;;;   If compiling in compile-toplevel, then *COMPILE-OBJECT* is a core object,
;;;   but if interpreting, then it is still a fasl.
;;; - once for compiling to fasl. *COMPILE-OBJECT* is a fasl.
;;; I'd have liked the data to be associated with the fasl, except that
;;; as indicated above, the second line hides some information.
(defun style-warn-once (thing fmt-or-condition &rest args)
  (declare (notinline style-warn)) ; See COMPILER-STYLE-WARN for rationale
  (let* ((source-info *source-info*)
         (file-info (and (source-info-p source-info)
                         (source-info-file-info source-info)))
         (file-compiling-p (file-info-p file-info)))
    (flet ((match-p (entry)
             (destructuring-bind (entry-thing entry-fmt &rest entry-args) entry
               ;; THING is compared by EQ, FMT mostly by STRING=.
               (and (eq entry-thing thing)
                    (cond ((typep entry-fmt 'condition)
                           (and (typep fmt-or-condition 'condition)
                                (string= (princ-to-string entry-fmt)
                                         (princ-to-string fmt-or-condition))))
                          ((typep fmt-or-condition 'condition)
                           nil)
                          ;; If at least one is a FMT-CONTROL-PROXY
                          ;; the two should be either EQ or a
                          ;; mismatch.
                          ((not (stringp entry-fmt))
                           (and (not (stringp fmt-or-condition))
                                (eq entry-fmt fmt-or-condition)))
                          ((string= entry-fmt fmt-or-condition)))
                    ;; We don't want to walk into default values,
                    ;; e.g. (&optional (b #<insane-struct))
                    ;; because #<insane-struct> might be circular.
                    (equal-but-no-car-recursion entry-args args)))))
      (unless (and file-compiling-p
                   (find-if #'match-p
                            (file-info-style-warning-tracker file-info)))
        (when file-compiling-p
          (push (list* thing fmt-or-condition args)
                (file-info-style-warning-tracker file-info)))
        (apply 'style-warn fmt-or-condition args)))))

;;;; component compilation

(defparameter *max-optimize-iterations* 3 ; ARB
  "The upper limit on the number of times that we will consecutively do IR1
optimization that doesn't introduce any new code. A finite limit is
necessary, since type inference may take arbitrarily long to converge.")

(defevent ir1-optimize-until-done "IR1-OPTIMIZE-UNTIL-DONE called")
(defevent ir1-optimize-maxed-out "hit *MAX-OPTIMIZE-ITERATIONS* limit")



;;; Repeatedly optimize COMPONENT until no further optimizations can
;;; be found or we hit our iteration limit. When we hit the limit, we
;;; clear the component and block REOPTIMIZE flags to discourage the
;;; next optimization attempt from pounding on the same code.
(defun ir1-optimize-until-done (component)
  (declare (type component component))
  (maybe-mumble "Opt")
  (event ir1-optimize-until-done)
  (let ((count 0)
        (cleared-reanalyze nil)
        (fastp nil))
    (loop
      (when (component-reanalyze component)
        (setf count 0
              fastp nil
              cleared-reanalyze t
              (component-reanalyze component) nil))
      (setf (component-reoptimize component) nil)
      (ir1-optimize component fastp)
      (cond ((component-reoptimize component)
             (incf count)
             (when (and (>= count *max-optimize-iterations*)
                        (not (component-reanalyze component))
                        (eq (component-reoptimize component) :maybe))
               (maybe-mumble "*")
               (cond ((retry-delayed-ir1-transforms :optimize)
                      (maybe-mumble "+")
                      (setq count 0))
                     (t
                      (event ir1-optimize-maxed-out)
                      (ir1-optimize-last-effort component)
                      (return)))))
            ((retry-delayed-ir1-transforms :optimize)
             (setf count 0)
             (maybe-mumble "+"))
            (t
             (return)))
      (when (setq fastp (>= count *max-optimize-iterations*))
        (ir1-optimize-last-effort component))
      (maybe-mumble (if fastp "-" ".")))
    (when cleared-reanalyze
      (setf (component-reanalyze component) t))
    (maybe-mumble " "))
  (values))

(defparameter *constraint-propagate* t)

(defevent reoptimize-maxed-out
  "*REOPTIMIZE-AFTER-TYPE-CHECK-MAX* exceeded.")

;;; Iterate doing FIND-DFO until no new dead code is discovered.
(defun dfo-as-needed (component)
  (declare (type component component))
  (when (component-reanalyze component)
    (maybe-mumble "DFO")
    (loop
      (find-dfo component)
      (unless (component-reanalyze component)
        (maybe-mumble " ")
        (return))
      (maybe-mumble ".")))
  (values))

(defparameter *reoptimize-limit* 10)

(defun ir1-optimize-phase-1 (component)
  (let ((loop-count 0)
        (*constraint-propagate* *constraint-propagate*))
    (tagbody
     again
       (loop
        (ir1-optimize-until-done component)
        (when (or (component-new-functionals component)
                  (component-reanalyze-functionals component))
          (maybe-mumble "Locall ")
          (locall-analyze-component component))
        (eliminate-dead-code component)
        (dfo-as-needed component)
        (when *constraint-propagate*
          (maybe-mumble "Constraint ")
          (constraint-propagate component)
          (when (retry-delayed-ir1-transforms :constraint)
            (setf loop-count 0) ;; otherwise nothing may get retried
            (maybe-mumble "Rtran ")))
        (unless (or (component-reoptimize component)
                    (component-reanalyze component)
                    (component-new-functionals component)
                    (component-reanalyze-functionals component))
          (return))
        (when (> loop-count *reoptimize-limit*)
          (maybe-mumble "[Reoptimize Limit]")
          (event reoptimize-maxed-out)
          (return))
        (incf loop-count))
       ;; Do it once more for the transforms that will produce code
       ;; that loses some information for further optimizations and
       ;; it's better to insert it at the last moment.
       ;; Such code shouldn't need constraint propagation, the slowest
       ;; part, so avoid it.
       (when (retry-delayed-ir1-transforms :ir1-phases)
         (setf loop-count 0
               *constraint-propagate* nil)
         (go again)))))

;;; Do all the IR1 phases for a non-top-level component.
(defun ir1-phases (component)
  (declare (type component component))
  (aver-live-component component)
  (let ((*constraint-universe* (make-array 64 ; arbitrary, but don't make this 0
                                           :fill-pointer 0 :adjustable t))
        (*delayed-ir1-transforms* nil))
    (declare (special *constraint-universe* *delayed-ir1-transforms*))
    (ir1-optimize-phase-1 component)
    (loop while (progn
                  (maybe-mumble "Type ")
                  (generate-type-checks component))
          do
          (ir1-optimize-phase-1 component))
    ;; Join the blocks that were generated by GENERATE-TYPE-CHECKS
    ;; now that all the blocks have the same TYPE-CHECK attribute
    (join-blocks-if-possible component))

  (ir1-finalize component)
  (values))

;;; COMPILE-FILE usually puts all nontoplevel code in immobile space, but COMPILE
;;; offers a choice. Because the immobile space GC does not run often enough (yet),
;;; COMPILE usually places code in the dynamic space managed by our copying GC.
;;; Change this variable if your application always demands immobile code.
;;; In particular, ELF cores shrink the immobile code space down to just enough
;;; to contain all code, plus about 1/2 MiB of spare, which means that you can't
;;; subsequently compile a whole lot into immobile space.
;;; The value is changed to :AUTO in make-target-2-load.lisp which supresses
;;; codegen optimizations for immobile space, but nonetheless prefers to allocate
;;; the code there, falling back to dynamic space if there is no room left.
;;; These controls exist whether or not the immobile-space feature is present.
(declaim (type (member :immobile :dynamic :auto) *compile-to-memory-space*)
         (type (member :immobile :dynamic) *compile-file-to-memory-space*))
(defvar *compile-to-memory-space* :immobile) ; BUILD-TIME default
(defvar *compile-file-to-memory-space* :immobile) ; BUILD-TIME default

#-immobile-code
(defun component-mem-space (component)
  (component-%mem-space component))

#+immobile-code
(progn
  (defun component-mem-space (component)
    (or (component-%mem-space component)
        (setf (component-%mem-space component)
              (if (fasl-output-p *compile-object*)
                  (and (eq *compile-file-to-memory-space* :immobile)
                       (neq (component-kind component) :toplevel)
                       (policy *lexenv* (/= sb-c:store-coverage-data 3))
                       :immobile)
                  (if (core-object-ephemeral *compile-object*)
                      :dynamic
                      *compile-to-memory-space*)))))
  (defun code-immobile-p (thing)
    #+sb-xc-host (declare (ignore thing)) #+sb-xc-host t
    #-sb-xc-host
    (let ((component (typecase thing
                       (vop  (node-component (vop-node thing)))
                       (node (node-component thing))
                       (t    thing))))
      (eq (component-mem-space component) :immobile))))

(defun %compile-component (component)
  (let ((*adjustable-vectors* nil)) ; Needed both by codegen and fasl writer
    (maybe-mumble "GTN ")
    (gtn-analyze component)
    (maybe-mumble "LTN ")
    (ltn-analyze component)
    (dfo-as-needed component)

    (maybe-mumble "Control ")
    (control-analyze component)

    (report-code-deletion)

    (when (or (ir2-component-values-receivers (component-info component))
              (component-dx-lvars component))
      (maybe-mumble "Stack ")
      ;; STACK only uses dominance information for DX LVAR back
      ;; propagation (see BACK-PROPAGATE-ONE-DX-LVAR).
      (when (component-dx-lvars component)
        (clear-dominators component)
        (find-dominators component))
      (stack-analyze component)
      ;; Assign BLOCK-NUMBER for any cleanup blocks introduced by
      ;; stack analysis. There shouldn't be any unreachable code after
      ;; control, so this won't delete anything.
      (dfo-as-needed component))

    (unwind-protect
        (progn
          (maybe-mumble "IR2Tran ")
          (entry-analyze component)
          (ir2-convert component)

          (when (policy *lexenv* (>= speed compilation-speed))
            (maybe-mumble "Copy ")
            (copy-propagate component))

          (ir2-optimize component)

          (select-representations component)
          ;; Try to combine consecutive uses of %INSTANCE-SET.
          ;; This can't be done prior to selecting representations
          ;; because SELECT-REPRESENTATIONS might insert some
          ;; things like MOVE-FROM-DOUBLE which makes the
          ;; "consecutive" vops no longer consecutive.
          (ir2-optimize-stores component)

          (when *check-consistency*
            (maybe-mumble "Check2 ")
            (check-ir2-consistency component))

          (delete-unreferenced-tns component)

          (maybe-mumble "Life ")
          (lifetime-analyze component)

          (when *compile-progress*
            (compiler-mumble "") ; Sync before doing more output.
            (pre-pack-tn-stats component *standard-output*))

          (when *check-consistency*
            (maybe-mumble "CheckL ")
            (check-life-consistency component))

          (maybe-mumble "Pack ")
          (sb-regalloc:pack component)

          (when *check-consistency*
            (maybe-mumble "CheckP ")
            (check-pack-consistency component))

          (delete-no-op-vops component)
          (ir2-optimize-jumps component)
          (optimize-constant-loads component)
          (when *compiler-trace-output*
            (when (memq :ir1 *compile-trace-targets*)
              (describe-component component *compiler-trace-output*))
            (when (memq :ir2 *compile-trace-targets*)
              (describe-ir2-component component *compiler-trace-output*)))

          (maybe-mumble "Code ")
          (multiple-value-bind (segment text-length fun-table
                                elsewhere-label fixup-notes alloc-points)
              (let ((*compiler-trace-output*
                      (and (memq :vop *compile-trace-targets*)
                           *compiler-trace-output*)))
                (generate-code component))
            (declare (ignorable text-length fun-table))

            (let ((bytes (sb-assem:segment-contents-as-vector segment))
                  (object *compile-object*)
                  (*elsewhere-label* elsewhere-label)) ; KLUDGE

              #-sb-xc-host
              (when (and *compiler-trace-output*
                         (memq :disassemble *compile-trace-targets*))
                (let ((ranges
                        (maplist (lambda (list)
                                   (cons (+ (car list)
                                            (ash sb-vm:simple-fun-insts-offset
                                                 sb-vm:word-shift))
                                         (or (cadr list) text-length)))
                                 fun-table)))
                  (format *compiler-trace-output*
                          "~|~%Disassembly of code for ~S~2%" component)
                  (sb-disassem:disassemble-assem-segment
                   bytes ranges *compiler-trace-output*)))

              (funcall (etypecase object
                         (fasl-output (maybe-mumble "FASL") #'fasl-dump-component)
                         #-sb-xc-host   ; no compiling to core
                         (core-object (maybe-mumble "Core") #'make-core-component)
                         (null (lambda (&rest dummies)
                                 (declare (ignore dummies)))))
                       component segment (length bytes)
                       fixup-notes alloc-points
                       object))))))

  ;; We're done, so don't bother keeping anything around.
  (setf (component-info component) :dead)

  (values))

;;; Delete components with no external entry points before we try to
;;; generate code. Unreachable closures can cause IR2 conversion to
;;; puke on itself, since it is the reference to the closure which
;;; normally causes the components to be combined.
(defun delete-if-no-entries (component)
  (dolist (fun (component-lambdas component) (delete-component component))
    (when (functional-has-external-references-p fun)
      (return))
    (case (functional-kind fun)
      (:toplevel (return))
      (:external
       (unless (every (lambda (ref)
                        (eq (node-component ref) component))
                      (leaf-refs fun))
         (return))))))

(defvar *compile-component-hook* nil)

(defun compile-component (component)

  ;; miscellaneous sanity checks
  ;;
  ;; FIXME: These are basically pretty wimpy compared to the checks done
  ;; by the old CHECK-IR1-CONSISTENCY code. It would be really nice to
  ;; make those internal consistency checks work again and use them.
  (aver-live-component component)
  (do-blocks (block component)
    (aver (eql (block-component block) component)))
  (dolist (lambda (component-lambdas component))
    ;; sanity check to prevent weirdness from propagating insidiously as
    ;; far from its root cause as it did in bug 138: Make sure that
    ;; thing-to-COMPONENT links are consistent.
    (aver (eql (lambda-component lambda) component))
    (aver (eql (node-component (lambda-bind lambda)) component)))

  (let* ((*component-being-compiled* component))

    (when *compile-progress*
      (compiler-mumble "~&")
      (pprint-logical-block (*standard-output* nil :per-line-prefix "; ")
        (compiler-mumble "Compiling ~A: " (component-name component))))

    ;; Record xref information before optimization. This way the
    ;; stored xref data reflects the real source as closely as
    ;; possible.
    (record-component-xrefs component)

    (ir1-phases component)

    ;; This should happen at some point before ENVIRONMENT-ANALYZE,
    ;; and after RECORD-COMPONENT-XREFS.  Beyond that, I haven't
    ;; really thought things through.  -- AJB, 2014-Jun-08
    (eliminate-dead-code component)

    (when *loop-analyze*
      (dfo-as-needed component)
      (maybe-mumble "Dom ")
      (find-dominators component)
      (maybe-mumble "Loop ")
      (loop-analyze component))

    #|
    (when (and *loop-analyze* *compiler-trace-output*)
      (labels ((print-blocks (block)
                 (format *compiler-trace-output* "    ~A~%" block)
                 (when (block-loop-next block)
                   (print-blocks (block-loop-next block))))
               (print-loop (loop)
                 (format *compiler-trace-output* "loop=~A~%" loop)
                 (print-blocks (loop-blocks loop))
                 (dolist (l (loop-inferiors loop))
                   (print-loop l))))
        (print-loop (component-outer-loop component))))
    |#

    (maybe-mumble "Env ")
    (environment-analyze component)
    (dfo-as-needed component)

    (delete-if-no-entries component)

    (if (eq (block-next (component-head component))
            (component-tail component))
        (report-code-deletion)
        (%compile-component component))
    (when *compile-component-hook*
      (funcall *compile-component-hook* component)))

  (clear-constant-info)
  (values))

;;;; clearing global data structures
;;;;
;;;; FIXME: Is it possible to get rid of this stuff, getting rid of
;;;; global data structures entirely when possible and consing up the
;;;; others from scratch instead of clearing and reusing them?

;;; Clear the INFO in constants in the *IR1-NAMESPACE*, etc. In
;;; addition to allowing stuff to be reclaimed, this is required for
;;; correct assignment of constant offsets, since we need to assign a
;;; new offset for each component. We don't clear the FUNCTIONAL-INFO
;;; slots, since they are used to keep track of functions across
;;; component boundaries.
(defun clear-constant-info (&aux (ns *ir1-namespace*))
  (maphash (lambda (k v)
             (declare (ignore k))
             (setf (leaf-info v) nil))
           (eql-constants ns))
  (maphash (lambda (k v)
             (declare (ignore k))
             (when (constant-p v)
               (setf (leaf-info v) nil)))
           (free-vars ns))
  (values))

;;; Blow away the REFS for all global variables, and let COMPONENT
;;; be recycled.
(defun clear-ir1-info (component &aux (ns *ir1-namespace*))
  (declare (type component component))
  (labels ((blast (x)
             (maphash (lambda (k v)
                        (declare (ignore k))
                        (when (leaf-p v)
                          (setf (leaf-refs v)
                                (delete-if #'here-p (leaf-refs v)))
                          (when (basic-var-p v)
                            (setf (basic-var-sets v)
                                  (delete-if #'here-p (basic-var-sets v))))))
                      x))
           (here-p (x)
             (eq (node-component x) component)))
    (blast (free-vars ns))
    (blast (free-funs ns))
    ;; There can be more constants to blast when considering them by EQL rather
    ;; than similarity. But it's totally OK to visit a #<CONSTANT> twice.
    ;; Its refs will be scanned redundantly, which is harmless.
    (blast (eql-constants ns)))
  (values))

;;;; trace output

;;; Print out some useful info about COMPONENT to STREAM.
(defun describe-component (component *standard-output*)
  (declare (type component component))
  (format t "~|~%;;;; component: ~S~2%" (component-name component))
  (print-all-blocks component)
  (values))

(defun describe-ir2-component (component *standard-output*)
  (format t "~%~|~%;;;; IR2 component: ~S~2%" (component-name component))
  (format t "entries:~%")
  (dolist (entry (ir2-component-entries (component-info component)))
    (format t "~4TL~D: ~S~:[~; [closure]~]~%"
            (label-id (entry-info-offset entry))
            (entry-info-name entry)
            (entry-info-closure-tn entry)))
  (terpri)
  (pre-pack-tn-stats component *standard-output*)
  (terpri)
  (print-ir2-blocks component)
  (terpri)
  (values))

;;; Leave this as NIL if you want modern, rational, correct, behavior,
;;; or switch it to T for legacy (CLHS-specified) bullshit a la
;;;  "During a call to compile-file, *compile-file-pathname* is bound to the pathname
;;;   denoted by the first argument to compile-file, merged against the defaults"
;;; The normal build sets it to T in make-target-2, despite that I think most people would
;;; prefer the nonstandard behavior. The standard behavior makes stored pathnames all wrong
;;; when files are physically moved. (Same problem as SBCL_HOME embedded into C pretty much)
(defglobal *merge-pathnames* nil)

;;; Given a pathname, return a SOURCE-INFO structure.
(defun make-file-source-info (file external-format &optional form-tracking-p)
  (make-source-info
   :file-info (make-file-info :pathname ; becomes *C-F-PATHNAME*
                              (if *merge-pathnames* (merge-pathnames file) file)
                              :external-format external-format
                              :subforms
                              (if form-tracking-p
                                  (make-array 100 :fill-pointer 0 :adjustable t))
                              :write-date (file-write-date file))))

;; LOAD-AS-SOURCE uses this.
(defun make-file-stream-source-info (file-stream)
  (make-source-info
   :file-info (make-file-info :truename (truename file-stream)
                              ;; This T-L-P has been around since at least 2011.
                              ;; It's unclear why an LPN isn't good enough.
                              :pathname (translate-logical-pathname file-stream)
                              :external-format (stream-external-format file-stream)
                              :write-date (file-write-date file-stream))))

;;; Return a SOURCE-INFO to describe the incremental compilation of FORM.
(defun make-lisp-source-info (form &key parent)
  (make-source-info
   :file-info (make-file-info :truename :lisp
                              :forms (vector form)
                              :positions '#(0))
   :parent parent))

;;; Walk up the SOURCE-INFO list until we either reach a SOURCE-INFO
;;; with no parent (e.g., from a REPL evaluation) or until we reach a
;;; SOURCE-INFO whose FILE-INFO denotes a file.
(defun get-toplevelish-file-info (&optional (source-info *source-info*))
  (if source-info
      (do* ((sinfo source-info (source-info-parent sinfo))
            (finfo (source-info-file-info sinfo)
                   (source-info-file-info sinfo)))
           ((or (not (source-info-p (source-info-parent sinfo)))
                (pathnamep (file-info-truename finfo)))
            finfo))))

;;; If STREAM is present, return it, otherwise open a stream to the
;;; current file. There must be a current file.
;;;
;;; FIXME: This is probably an unnecessarily roundabout way to do
;;; things now that we process a single file in COMPILE-FILE (unlike
;;; the old CMU CL code, which accepted multiple files). Also, the old
;;; comment said
;;;   When we open a new file, we also reset *PACKAGE* and policy.
;;;   This gives the effect of rebinding around each file.
;;; which doesn't seem to be true now. Check to make sure that if
;;; such rebinding is necessary, it's still done somewhere.
(defun get-source-stream (info)
  (declare (type source-info info))
  (or (source-info-stream info)
      (let* ((file-info (source-info-file-info info))
             (pathname (file-info-pathname file-info))
             (external-format (file-info-external-format file-info)))
        (let ((stream
               (open pathname
                     :direction :input
                     :external-format external-format
                     ;; SBCL stream classes aren't available in the host
                     #-sb-xc-host :class
                     #-sb-xc-host 'form-tracking-stream)))
          ;; If you don't want merged pathnames embedded in your build artifacts,
          ;; then you surely don't want them in *COMPILE-FILE-PATHNAME* either.
          ;; [And can't we just bind this to PATHNAME is all cases? If anything,
          ;; it seems to me that asking the stream for its name is expressly backwards]
          (setf *compile-file-pathname* (if *merge-pathnames* (pathname stream) pathname)
                *compile-file-truename* (truename stream)
                (file-info-truename file-info) *compile-file-truename*)
          (when (file-info-subforms file-info)
            (setf (form-tracking-stream-observer stream)
                  (make-form-tracking-stream-observer file-info)))
          (setf (source-info-stream info) stream)
          ;; This used to happen before opening the file, which
          ;; inhibited lazy computation of the truename, and was a
          ;; minor time-of-check-vs-time-of-use mistake. It doesn't
          ;; seem worthwhile to pass the verbose bit down from C-F,
          ;; however.
          (when *compile-verbose*
            (print-compile-start-note info))
          stream))))

;;; Close the stream in INFO if it is open.
(defun close-source-info (info)
  (declare (type source-info info))
  (let ((stream (source-info-stream info)))
    (when stream (close stream)))
  (setf (source-info-stream info) nil)
  (values))

;; Loop over forms read from INFO's stream, calling FUNCTION with each.
;; CONDITION-NAME is signaled if there is a reader error, and should be
;; a subtype of not-so-aptly-named INPUT-ERROR-IN-COMPILE-FILE.
(defun %do-forms-from-info (function info condition-name)
  (declare (function function))
  ; FIXME: why "could not stack-allocate" in a few call sites?
  ; (declare (dynamic-extent function))
  (let* ((file-info (source-info-file-info info))
         (stream (get-source-stream info))
         (pos (file-position stream))
         (form
          ;; Return a form read from STREAM; or for EOF use the trick,
          ;; popularized by Kent Pitman, of returning STREAM itself.
          (handler-case
              (progn
                ;; Reset for a new toplevel form.
                (when (form-tracking-stream-p stream)
                  (setf (form-tracking-stream-form-start-char-pos stream) nil))
                (awhen (file-info-subforms file-info)
                  (setf (fill-pointer it) 0))
                (read-preserving-whitespace stream nil stream))
            (reader-error (condition)
              (compiler-error condition-name
                ;; We don't need to supply :POSITION here because
                ;; READER-ERRORs already know their position in the file.
                              :condition condition
                              :stream stream))
            ;; ANSI, in its wisdom, says that READ should return END-OF-FILE
            ;; (and that this is not a READER-ERROR) when it encounters end of
            ;; file in the middle of something it's trying to read,
            ;; making it unfortunately indistinguishable from legal EOF.
            ;; Were it not for that, it would be more elegant to just
            ;; handle one more condition in the HANDLER-CASE.
            ((or end-of-file error) (condition)
              (compiler-error
               condition-name
               :condition condition
                ;; We need to supply :POSITION here because the END-OF-FILE
                ;; condition doesn't carry the position that the user
                ;; probably cares about, where the failed READ began.
               :position
               (or (and (form-tracking-stream-p stream)
                        (form-tracking-stream-form-start-byte-pos stream))
                   pos)
               :line/col
               (and (form-tracking-stream-p stream)
                    (line/col-from-charpos
                     stream
                     (form-tracking-stream-form-start-char-pos stream)))
               :stream stream)))))
    (unless (eq form stream) ; not EOF
      (funcall function form
               :current-index
               (let* ((forms (file-info-forms file-info))
                      (current-idx (fill-pointer forms)))
                 (vector-push-extend form forms)
                 (vector-push-extend pos (file-info-positions file-info))
                 current-idx))
      (%do-forms-from-info function info condition-name))))

;;; Loop over FORMS retrieved from INFO.  Used by COMPILE-FILE and
;;; LOAD when loading from a FILE-STREAM associated with a source
;;; file.  ON-ERROR is the name of a condition class that should
;;; be signaled if anything goes wrong during a READ.
(defmacro do-forms-from-info (((form &rest keys) info
                               &optional (on-error ''input-error-in-load))
                              &body body)
  (aver (symbolp form))
  (once-only ((info info))
    `(let ((*source-info* ,info))
       (%do-forms-from-info (lambda (,form &key ,@keys &allow-other-keys)
                              ,@body)
                            ,info ,on-error))))

;;; Return the INDEX'th source form read from INFO and the position
;;; where it was read.
(defun find-source-root (index info)
  (declare (type index index) (type source-info info))
  (let ((file-info (source-info-file-info info)))
    (values (aref (file-info-forms file-info) index)
            (aref (file-info-positions file-info) index))))

;;;; processing of top level forms

;;; This is called by top level form processing when we are ready to
;;; actually compile something. If (BLOCK-COMPILE *COMPILATION*) is T,
;;; then we still convert the form, but delay compilation, pushing the result
;;; on (TOPLEVEL-LAMBDAS *COMPILATION*) instead.
(defun convert-and-maybe-compile (form path &optional (expand t))
  (declare (list path))
  #+sb-xc-host
  (when sb-cold::*compile-for-effect-only*
    (return-from convert-and-maybe-compile))
  ;; Don't bother to compile simple objects that just sit there.
  (when (and form (or (symbolp form) (consp form)))
    (if (and #-sb-xc-host
             (policy *policy*
                 ;; FOP-compiled code is harder to debug.
                 (or (< debug 2)
                     (> space debug)))
             (not (eq (block-compile *compilation*) t))
             (fopcompilable-p form expand))
        (let ((*fopcompile-label-counter* 0))
          (fopcompile form path nil expand))
        (let ((*lexenv* (make-lexenv
                         :policy *policy*
                         :handled-conditions *handled-conditions*
                         :disabled-package-locks *disabled-package-locks*))
              (tll (ir1-toplevel form path nil)))
          (if (eq (block-compile *compilation*) t)
              (push tll (toplevel-lambdas *compilation*))
              (compile-toplevel (list tll) nil))
          (when (consp form)
            (case (car form)
              ;; Block compilation can cause packages to be defined after
              ;; they are referenced at load time, so we have to delimit the
              ;; current block compilation.
              ((sb-impl::%defpackage)
               (delimit-block-compilation))))
          nil))))

;;; Macroexpand FORM in the current environment with an error handler.
;;; We only expand one level, so that we retain all the intervening
;;; forms in the source path. A compiler-macro takes precedence over
;;; an ordinary macro as specified in CLHS 3.2.3.1
;;; Note that this function is _only_ for processing of toplevel forms.
;;; Non-toplevel forms use IR1-CONVERT-FUNCTOID which considers compiler macros.
(defun preprocessor-macroexpand-1 (form)
  (when (listp form)
    (let ((expansion (expand-compiler-macro form)))
      (unless (eq expansion form)
        (return-from preprocessor-macroexpand-1
          (values expansion t)))))
  (handler-bind
      ((error (lambda (condition)
                (compiler-error "(during macroexpansion of ~A)~%~A"
                                (let ((*print-level* 2)
                                      (*print-length* 2))
                                  (format nil "~S" form))
                                condition))))
    (%macroexpand-1 form *lexenv*)))

;;; Process a PROGN-like portion of a top level form. FORMS is a list of
;;; the forms, and PATH is the source path of the FORM they came out of.
;;; COMPILE-TIME-TOO is as in ANSI "3.2.3.1 Processing of Top Level Forms".
(defun process-toplevel-progn (forms path compile-time-too)
  (declare (list forms) (list path))
  (dolist (form forms)
    (process-toplevel-form form path compile-time-too)))

;;; Process a top level use of LOCALLY, or anything else (e.g.
;;; MACROLET) at top level which has declarations and ordinary forms.
;;; We parse declarations and then recursively process the body.
(defun process-toplevel-locally (body path compile-time-too &key vars funs)
  (declare (list path))
  (multiple-value-bind (forms decls) (parse-body body nil t)
    (let* ((*lexenv* (process-decls decls vars funs))
           ;; FIXME: VALUES declaration
           ;;
           ;; Binding *POLICY* is pretty much of a hack, since it
           ;; causes LOCALLY to "capture" enclosed proclamations. It
           ;; is necessary because CONVERT-AND-MAYBE-COMPILE uses the
           ;; value of *POLICY* as the policy. The need for this hack
           ;; is due to the quirk that there is no way to represent in
           ;; a POLICY that an optimize quality came from the default.
           ;;
           ;; FIXME: Ideally, something should be done so that DECLAIM
           ;; inside LOCALLY works OK. Failing that, at least we could
           ;; issue a warning instead of silently screwing up.
           ;; Here's how to fix this: a POLICY object can in fact represent
           ;; absence of qualitities. Whenever we rebind *POLICY* (here and
           ;; elsewhere), it should be bound to a policy that expresses no
           ;; qualities. Proclamations should update SYMBOL-GLOBAL-VALUE of
           ;; *POLICY*, which can be seen irrespective of dynamic bindings,
           ;; and declarations should update the lexical policy.
           ;; The POLICY macro can be amended to merge the dynamic *POLICY*
           ;; (or whatever it came from, like a LEXENV) with the global
           ;; *POLICY*. COERCE-TO-POLICY can do the merge, employing a 1-line
           ;; cache so that repeated calls for any two fixed policy objects
           ;; return the identical value (since policies are immutable).
           (*policy* (lexenv-policy *lexenv*))
           ;; This is probably also a hack
           (*handled-conditions* (lexenv-handled-conditions *lexenv*))
           ;; ditto
           (*disabled-package-locks* (lexenv-disabled-package-locks *lexenv*)))
      (process-toplevel-progn forms path compile-time-too))))

;;; Parse an EVAL-WHEN situations list, returning three flags,
;;; (VALUES COMPILE-TOPLEVEL LOAD-TOPLEVEL EXECUTE), indicating
;;; the types of situations present in the list.
(defun parse-eval-when-situations (situations)
  (when (or (not (listp situations))
            (set-difference situations
                            '(:compile-toplevel
                              compile
                              :load-toplevel
                              load
                              :execute
                              eval)))
    (compiler-error "bad EVAL-WHEN situation list: ~S" situations))
  (let ((deprecated-names (intersection situations '(compile load eval))))
    (when deprecated-names
      (style-warn "using deprecated EVAL-WHEN situation names~{ ~S~}"
                  deprecated-names)))
  (values (intersection '(:compile-toplevel compile)
                        situations)
          (intersection '(:load-toplevel load) situations)
          (intersection '(:execute eval) situations)))


;;; utilities for extracting COMPONENTs of FUNCTIONALs
(defun functional-components (f)
  (declare (type functional f))
  (etypecase f
    (clambda (list (lambda-component f)))
    (optional-dispatch (let ((result nil))
                         (flet ((maybe-frob (maybe-clambda)
                                  (when (and maybe-clambda
                                             (promise-ready-p maybe-clambda))
                                    (pushnew (lambda-component
                                              (force maybe-clambda))
                                             result))))
                           (map nil #'maybe-frob (optional-dispatch-entry-points f))
                           (maybe-frob (optional-dispatch-more-entry f))
                           (maybe-frob (optional-dispatch-main-entry f)))
                         result))))

(defun make-functional-from-toplevel-lambda (lambda-expression
                                             &key
                                             name
                                             (path
                                              ;; I'd thought NIL should
                                              ;; work, but it doesn't.
                                              ;; -- WHN 2001-09-20
                                              (missing-arg)))
  (let* ((*current-path* path)
         (component (make-empty-component))
         (*current-component* component)
         (debug-name-tail (or name (name-lambdalike lambda-expression)))
         (source-name (or name '.anonymous.)))
    (setf (component-name component) (debug-name 'initial-component debug-name-tail)
          (component-kind component) :initial)
    (let* ((fun (let ((*allow-instrumenting* t))
                  (ir1-convert-lambdalike lambda-expression
                                          :source-name source-name)))
           ;; Convert the XEP using the policy of the real function. Otherwise
           ;; the wrong policy will be used for deciding whether to type-check
           ;; the parameters of the real function (via CONVERT-CALL /
           ;; PROPAGATE-TO-ARGS). -- JES, 2007-02-27
           (*lexenv* (make-lexenv :policy (lexenv-policy (functional-lexenv fun))))
           (xep (ir1-convert-lambda (make-xep-lambda-expression fun)
                                    :source-name source-name
                                    :debug-name (debug-name 'tl-xep debug-name-tail)
                                    :system-lambda t)))
      (when name
        (assert-global-function-definition-type name fun))
      (setf (functional-kind xep) :external
            (functional-entry-fun xep) fun
            (functional-entry-fun fun) xep
            (component-reanalyze component) t
            (functional-has-external-references-p xep) t)
      (reoptimize-component component :maybe)
      (locall-analyze-xep-entry-point fun)
      ;; Any leftover REFs to FUN outside local calls get replaced with the
      ;; XEP.
      (substitute-leaf-if (lambda (ref)
                            (let* ((lvar (ref-lvar ref))
                                   (dest (when lvar (lvar-dest lvar)))
                                   (kind (when (basic-combination-p dest)
                                           (basic-combination-kind dest))))
                              (neq :local kind)))
                          xep
                          fun)
      xep)))

;;; Compile LAMBDA-EXPRESSION into *COMPILE-OBJECT*, returning a
;;; description of the result.
;;;   * If *COMPILE-OBJECT* is a CORE-OBJECT, then write the function
;;;     into core and return the compiled FUNCTION value.
;;;   * If *COMPILE-OBJECT* is a fasl file, then write the function
;;;     into the fasl file and return a dump handle.
;;;
;;; If NAME is provided, then we try to use it as the name of the
;;; function for debugging/diagnostic information.
(defun %compile (lambda-expression object
                 &key
                 name
                 (path
                  ;; This magical idiom seems to be the appropriate
                  ;; path for compiling standalone LAMBDAs, judging
                  ;; from the CMU CL code and experiment, so it's a
                  ;; nice default for things where we don't have a
                  ;; real source path (as in e.g. inside CL:COMPILE).
                  '(original-source-start 0 0))
                 &aux (*compile-object* object))
  (when name
    (legal-fun-name-or-type-error name))
  (with-ir1-namespace
    (let* ((*lexenv* (make-lexenv
                      :policy *policy*
                      :handled-conditions *handled-conditions*
                      :disabled-package-locks *disabled-package-locks*))
           (fun (make-functional-from-toplevel-lambda lambda-expression
                                                      :name name
                                                      :path path)))

      ;; FIXME: The compile-it code from here on is sort of a
      ;; twisted version of the code in COMPILE-TOPLEVEL. It'd be
      ;; better to find a way to share the code there; or
      ;; alternatively, to use this code to replace the code there.
      ;; (The second alternative might be pretty easy if we used
      ;; the :LOCALL-ONLY option to IR1-FOR-LAMBDA. Then maybe the
      ;; whole FUNCTIONAL-KIND=:TOPLEVEL case could go away..)

      (locall-analyze-clambdas-until-done (list fun))

      (let ((components-from-dfo (find-initial-dfo (list fun))))
        (dolist (component-from-dfo components-from-dfo)
          (compile-component component-from-dfo)
          (replace-toplevel-xeps component-from-dfo))

        (let ((entry-table (etypecase object
                             (fasl-output (fasl-output-entry-table object))
                             (core-object (core-object-entry-table object)))))
          (multiple-value-bind (result found-p)
              (gethash (leaf-info fun) entry-table)
            (aver found-p)

            (when (core-object-p object)
              #+sb-xc-host (error "Can't compile to core")
              #-sb-xc-host
              (let ((store-source
                      (policy (lambda-bind fun)
                          (> store-source-form 0))))
                (fix-core-source-info *source-info* object
                                      (and store-source result))))
            (mapc #'clear-ir1-info components-from-dfo)
            result))))))

;;; Print some noise about FORM if *COMPILE-PRINT* is true.
(defun note-top-level-form (form)
  (when *compile-print*
    (let ((*print-length* 2)
          (*print-level* 2)
          (*print-pretty* nil))
      (with-compiler-io-syntax
        (compiler-mumble "~&; processing ~S" form)))))

;;; Handle the evaluation the a :COMPILE-TOPLEVEL body during
;;; compilation. Normally just evaluate in the appropriate
;;; environment, but also compile if outputting a CFASL.
(defun eval-compile-toplevel (body path)
  (let ((*compile-time-eval* t))
    (flet ((frob ()
             (eval-tlf `(progn ,@body) (source-path-tlf-number path) *lexenv*)
             (awhen (compile-toplevel-object *compilation*)
               (let ((*compile-object* it))
                 (convert-and-maybe-compile `(progn ,@body) path)))))
      (if (null *macro-policy*)
          (frob)
          ;; Macro policy is such a kludge. Most of the effect is conferred by
          ;; injecting declarations into any sexpr coming from MAKE-MACRO-LAMBDA.
          ;; But that's not enough - we need all code in EVAL-WHEN :COMPILE-TOPLEVEL
          ;; situations to run under the macro policy. This somewhat works by binding
          ;; *LEXENV*, but fails anywhere we use MAKE-NULL-LEXENV, which sees only
          ;; the policy in *POLICY* from the perspective of that lexenv.
          ;; So we have to change *POLICY* also, but without binding it, because
          ;; binding prevents toplevel DECLAIMs from taking effect.  As a workaround,
          ;; we assign *POLICY* but restore the original qualities whose values
          ;; were present in the macro policy.
          ;; e.g:
          ;;  - macro policy of (safety 3)
          ;;  - global policy of (safety 0) and (store-coverage-data 3)
          ;;  - some file wants to declaim (safety 1) (store-coverage-data 0)
          ;; So because the DECLAIM is an EVAL-WHEN :COMPILE-TOPLEVEL with a macro policy,
          ;; we would try to restore *POLICY* to (safety 0) (store-coverage-data 3)
          ;; immediately after eval'ing the DECLAIM, making it totally effectless.
          (let ((new-policy (process-optimize-decl
                             `(optimize ,@(policy-to-decl-spec *macro-policy*))
                             (lexenv-policy *lexenv*)))
                (old-policy *policy*))
            (unwind-protect
                 (let ((*lexenv* (make-lexenv :policy new-policy :default *lexenv*)))
                   (setf (saved-optimize-decls *compilation*) nil)
                   (setq *policy* new-policy)
                   (frob))
              ;; There are other ways to do this. e.g.: only save a declaim if it contained
              ;; a quality names intersecting with the ones in macro policy; then don't
              ;; restore everything to the start sate, merely undo changes from macro-policy,
              ;; but keeping the changes that were expressed by toplevel forms.
              ;; This is easiest and I really don't care to think about it.
              (let ((saved (saved-optimize-decls *compilation*)))
                (setf (saved-optimize-decls *compilation*) :none)
                (dolist (expr (nreverse saved)) ;; seldom anything here
                  (setq old-policy (process-optimize-decl expr old-policy)))
                (setq *policy* old-policy))))))))

;;; Process a top level FORM with the specified source PATH.
;;;  * If this is a magic top level form, then do stuff.
;;;  * If this is a macro, then expand it.
;;;  * Otherwise, just compile it.
;;;
;;; COMPILE-TIME-TOO is as defined in ANSI
;;; "3.2.3.1 Processing of Top Level Forms".
(defun process-toplevel-form (form path compile-time-too)
  (declare (list path))

  (catch 'process-toplevel-form-error-abort
    (let* ((path (or (get-source-path form) (cons form path)))
           (*current-path* path)
           (*compiler-error-bailout*
            (lambda (&optional condition)
              (convert-and-maybe-compile
               (make-compiler-error-form condition form)
               path)
              (throw 'process-toplevel-form-error-abort nil)))
           (*top-level-form-p* t))
      (case (if (listp form) (car form))
        ((eval-when macrolet symbol-macrolet) ; things w/ 1 arg before body
         (unless (cdr form)
           (compiler-error "~S form is too short: ~S" (car form) form))
         (destructuring-bind (special-operator magic &rest body) form
           (ecase special-operator
             ((eval-when)
              ;; CT, LT, and E here are as in Figure 3-7 of ANSI
              ;; "3.2.3.1 Processing of Top Level Forms".
              (multiple-value-bind (ct lt e) (parse-eval-when-situations magic)
                (let ((new-compile-time-too (or ct (and compile-time-too e))))
                  (cond (lt
                         (process-toplevel-progn body path new-compile-time-too))
                        (new-compile-time-too
                         (eval-compile-toplevel body path))))))
             ((macrolet)
              (funcall-in-macrolet-lexenv
               magic
               (lambda (&optional funs)
                 (process-toplevel-locally body path compile-time-too :funs funs))
               :compile))
             ((symbol-macrolet)
              (funcall-in-symbol-macrolet-lexenv
               magic
               (lambda (&optional vars)
                 (process-toplevel-locally body path compile-time-too :vars vars))
               :compile)))))
        ((locally)
         (process-toplevel-locally (rest form) path compile-time-too))
        ((progn)
         (process-toplevel-progn (rest form) path compile-time-too))
        (t
         (let ((expanded (preprocessor-macroexpand-1 form)))
           (cond ((neq expanded form) ; macro -> take it from the top
                  (process-toplevel-form expanded path compile-time-too))
                 (t
                  (when compile-time-too
                    (eval-compile-toplevel (list form) path))
                  (let (*top-level-form-p*)
                    (convert-and-maybe-compile form path)))))))))

  (values))

(defun copy-hash-table (hash-table)
  (let ((new (make-hash-table :test (hash-table-test hash-table)
                              :size (hash-table-size hash-table))))
    (maphash (lambda (key value)
               (setf (gethash key new) value))
             hash-table)
    new))

;;;; load time value support
;;;;
;;;; (See EMIT-MAKE-LOAD-FORM.)

;;; Return T if we are currently producing a fasl file and hence
;;; constants need to be dumped carefully.
(declaim (inline producing-fasl-file))
(defun producing-fasl-file ()
  (fasl-output-p *compile-object*))

;;; Compile FORM and arrange for it to be called at load-time. Return
;;; the dumper handle and our best guess at the type of the object.
;;; Potential optimizations: We could test the form for constantness
;;; (including FIND-PACKAGE forms) and dump it as a literal directly
;;; instead. We could also fopcompile more complex non-constant forms.
(defun compile-load-time-value (form &optional no-skip)
  (let ((lambda (compile-load-time-stuff form t)))
    (values (fasl-dump-load-time-value-lambda lambda *compile-object*
                                              no-skip)
            (let ((type (leaf-type lambda)))
              (if (fun-type-p type)
                  (single-value-type (fun-type-returns type))
                  *wild-type*)))))

;;; Compile the FORMS and arrange for them to be called (for effect,
;;; not value) at load time.
(defun compile-make-load-form-init-forms (forms fasl)
  ;; If FORMS has exactly one PROGN containing a call of SB-PCL::SET-SLOTS,
  ;; then fopcompile it, otherwise use the main compiler.
  (when (singleton-p forms)
    (let ((call (car forms)))
      (when (typep call '(cons (eql sb-pcl::set-slots) (cons instance)))
        (pop call)
        (let ((instance (pop call))
              (slot-names (pop call))
              (value-forms call)
              (values))
          (when (and (every #'symbolp slot-names)
                     (every (lambda (x)
                              ;; +SLOT-UNBOUND+ is not a constant,
                              ;; but is trivially dumpable.
                              (or (eql x 'sb-pcl:+slot-unbound+)
                                  (constantp x)))
                            value-forms))
            (dolist (form value-forms)
              (unless (eq form 'sb-pcl:+slot-unbound+)
                (let ((val (constant-form-value form)))
                  (maybe-emit-make-load-forms val)
                  (push val values))))
            (setq values (nreverse values))
            (dolist (form value-forms)
              (if (eq form 'sb-pcl:+slot-unbound+)
                  (dump-fop 'sb-fasl::fop-misc-trap fasl)
                  (dump-object (pop values) fasl)))
            (dump-object slot-names fasl)
            (dump-object instance fasl)
            (dump-fop 'sb-fasl::fop-set-slot-values fasl (length slot-names))
            (return-from compile-make-load-form-init-forms))))))
  (let ((lambda (compile-load-time-stuff `(progn ,@forms) nil)))
    (fasl-dump-toplevel-lambda-call lambda *compile-object*)))

;;; Do the actual work of COMPILE-LOAD-TIME-VALUE or
;;; COMPILE-MAKE-LOAD-FORM-INIT-FORMS.
(defun compile-load-time-stuff (form for-value)
  (with-ir1-namespace
   (let* ((*lexenv* (make-null-lexenv))
          (lambda (ir1-toplevel form *current-path* for-value nil)))
     (compile-toplevel (list lambda) t)
     lambda)))

;;; This is called by COMPILE-TOPLEVEL when it was passed T for
;;; LOAD-TIME-VALUE-P (which happens in COMPILE-LOAD-TIME-STUFF). We
;;; don't try to combine this component with anything else and frob
;;; the name. If not in a :TOPLEVEL component, then don't bother
;;; compiling, because it was merged with a run-time component.
(defun compile-load-time-value-lambda (lambdas)
  (aver (null (cdr lambdas)))
  (let* ((lambda (car lambdas))
         (component (lambda-component lambda)))
    (when (eql (component-kind component) :toplevel)
      (setf (component-name component) (leaf-debug-name lambda))
      (compile-component component)
      (clear-ir1-info component))))


;;; The entry point for MAKE-LOAD-FORM support. When IR1 conversion
;;; finds a constant structure, it invokes this to arrange for proper
;;; dumping. If it turns out that the constant has already been
;;; dumped, then we don't need to do anything.
;;;
;;; If the constant hasn't been dumped, then we check to see whether
;;; we are in the process of creating it. We detect this by
;;; maintaining the special *CONSTANTS-BEING-CREATED* as a list of all
;;; the constants we are in the process of creating. Actually, each
;;; entry is a list of the constant and any init forms that need to be
;;; processed on behalf of that constant.
;;;
;;; It's not necessarily an error for this to happen. If we are
;;; processing the init form for some object that showed up *after*
;;; the original reference to this constant, then we just need to
;;; defer the processing of that init form. To detect this, we
;;; maintain *CONSTANTS-CREATED-SINCE-LAST-INIT* as a list of the
;;; constants created since the last time we started processing an
;;; init form. If the constant passed to emit-make-load-form shows up
;;; in this list, then there is a circular chain through creation
;;; forms, which is an error.
;;;
;;; If there is some intervening init form, then we blow out of
;;; processing it by throwing to the tag PENDING-INIT. The value we
;;; throw is the entry from *CONSTANTS-BEING-CREATED*. This is so the
;;; offending init form can be tacked onto the init forms for the
;;; circular object.
;;;
;;; If the constant doesn't show up in *CONSTANTS-BEING-CREATED*, then
;;; we have to create it. We call %MAKE-LOAD-FORM and check
;;; if the result is 'FOP-STRUCT, and if so we don't do anything.
;;; The dumper will eventually get its hands on the object and use the
;;; normal structure dumping noise on it.
;;;
;;; Otherwise, we bind *CONSTANTS-BEING-CREATED* and
;;; *CONSTANTS-CREATED-SINCE- LAST-INIT* and compile the creation form
;;; much the way LOAD-TIME-VALUE does. When this finishes, we tell the
;;; dumper to use that result instead whenever it sees this constant.
;;;
;;; Now we try to compile the init form. We bind
;;; *CONSTANTS-CREATED-SINCE-LAST-INIT* to NIL and compile the init
;;; form (and any init forms that were added because of circularity
;;; detection). If this works, great. If not, we add the init forms to
;;; the init forms for the object that caused the problems and let it
;;; deal with it.
(defvar *constants-being-created*)
(defvar *constants-created-since-last-init*)
(defun emit-make-load-form (constant &aux (constants-being-created
                                           (if (boundp '*constants-being-created*)
                                               *constants-being-created*))
                                          (constants-created-since-last-init
                                           (if (boundp '*constants-created-since-last-init*)
                                               *constants-created-since-last-init*))
                                          (fasl *compile-object*))
  (aver (fasl-output-p fasl))
  (unless (fasl-constant-already-dumped-p constant fasl)
    (let ((circular-ref (assoc constant constants-being-created :test #'eq)))
      (when circular-ref
        (when (find constant constants-created-since-last-init :test #'eq)
          (throw constant t))
        (throw 'pending-init circular-ref)))
    (multiple-value-bind (creation-form init-form) (%make-load-form constant)
      (cond
        ((eq init-form 'sb-fasl::fop-struct)
         (fasl-note-dumpable-instance constant fasl)
         t)
        (t
         (let* ((name (write-to-string constant :level 1 :length 2))
                (info (if init-form
                          (list constant name init-form)
                          (list constant))))
           (let ((*constants-being-created* (cons info constants-being-created))
                 (*constants-created-since-last-init*
                  (cons constant constants-created-since-last-init)))
             (when
                 (catch constant
                   (fasl-note-handle-for-constant
                    constant
                    (cond ((typep creation-form
                                  '(cons (eql sb-kernel::new-instance)
                                         (cons symbol null)))
                           (dump-object (cadr creation-form) fasl)
                           (dump-fop 'sb-fasl::fop-allocate-instance fasl)
                           (let ((index (sb-fasl::fasl-output-table-free fasl)))
                             (setf (sb-fasl::fasl-output-table-free fasl) (1+ index))
                             index))
                          (t
                           (compile-load-time-value creation-form t)))
                    fasl)
                   nil)
               (compiler-error "circular references in creation form for ~S"
                               constant)))
           (when (cdr info)
             (let* ((*constants-created-since-last-init* nil)
                    (circular-ref
                     (catch 'pending-init
                       (loop for (nil form) on (cdr info) by #'cddr
                         collect form into forms
                         finally (compile-make-load-form-init-forms forms fasl))
                       nil)))
               (when circular-ref
                 (setf (cdr circular-ref)
                       (append (cdr circular-ref) (cdr info)))))))
         nil)))))


;;;; COMPILE-FILE

(defun object-call-toplevel-lambda (tll)
  (declare (type functional tll))
  (let ((object *compile-object*))
    (etypecase object
      (fasl-output (fasl-dump-toplevel-lambda-call tll object))
      (core-object (core-call-toplevel-lambda      tll object))
      (null))))

;;; Smash LAMBDAS into a single component, compile it, and arrange for
;;; the resulting function to be called.
(defun sub-compile-toplevel-lambdas (lambdas)
  (declare (list lambdas))
  (when lambdas
    (multiple-value-bind (component tll) (merge-toplevel-lambdas lambdas)
      (compile-component component)
      (clear-ir1-info component)
      (object-call-toplevel-lambda tll)))
  (values))

;;; Compile top level code and call the top level lambdas. We pick off
;;; top level lambdas in non-top-level components here, calling
;;; SUB-c-t-l-l on each subsequence of normal top level lambdas.
(defun compile-toplevel-lambdas (lambdas)
  (declare (list lambdas))
  (let ((len (length lambdas)))
    (flet ((loser (start)
             (or (position-if (lambda (x)
                                (not (eq (component-kind
                                          (node-component (lambda-bind x)))
                                         :toplevel)))
                              lambdas
                              ;; this used to read ":start start", but
                              ;; start can be greater than len, which
                              ;; is an error according to ANSI - CSR,
                              ;; 2002-04-25
                              :start (min start len))
                 len)))
      (do* ((start 0 (1+ loser))
            (loser (loser start) (loser start)))
           ((>= start len))
        (sub-compile-toplevel-lambdas (subseq lambdas start loser))
        (unless (= loser len)
          (object-call-toplevel-lambda (elt lambdas loser))))))
  (values))

;;; Compile LAMBDAS (a list of CLAMBDAs for top level forms) into the
;;; object file.
;;;
;;; LOAD-TIME-VALUE-P seems to control whether it's MAKE-LOAD-FORM and
;;; COMPILE-LOAD-TIME-VALUE stuff. -- WHN 20000201
(defun compile-toplevel (lambdas load-time-value-p)
  (declare (list lambdas))

  (maybe-mumble "Locall ")
  (locall-analyze-clambdas-until-done lambdas)

  (maybe-mumble "IDFO ")
  (multiple-value-bind (components top-components)
      (find-initial-dfo lambdas)
    (when *check-consistency*
      (maybe-mumble "[Check]~%")
      (check-ir1-consistency (append components top-components)))

    (dolist (component components)
      (compile-component component)
      (replace-toplevel-xeps component))

    (when *check-consistency*
      (maybe-mumble "[Check]~%")
      (check-ir1-consistency (append components top-components)))

    (if load-time-value-p
        (compile-load-time-value-lambda lambdas)
        (compile-toplevel-lambdas lambdas))

    (mapc #'clear-ir1-info components))
  (values))

;;; Actually compile any stuff that has been queued up for block
;;; compilation.
(defun finish-block-compilation ()
  (let ((compilation *compilation*))
    (when (block-compile compilation)
      (when (toplevel-lambdas compilation)
        ;; FIXME: Use the source information from the initial
        ;; conversion. CMUCL does this right.
        (with-source-paths
            (compile-toplevel (nreverse (toplevel-lambdas compilation)) nil))
        (setf (toplevel-lambdas compilation) nil))
      (setf (block-compile compilation) :specified)
      (setf (entry-points compilation) nil)
      (setf *hairy-defconstants* nil))))

(defun delimit-block-compilation ()
  (let ((compilation *compilation*))
    (when (block-compile compilation)
      (when (toplevel-lambdas compilation)
        (compile-toplevel (nreverse (toplevel-lambdas compilation)) nil)
        (setf (toplevel-lambdas compilation) nil)))))

(declaim (ftype function handle-condition-p))
(flet ((get-handled-conditions ()
         (if (boundp '*lexenv*)
             (let ((ctxt *compiler-error-context*))
               (etypecase ctxt
                 (node
                  (lexenv-handled-conditions (node-lexenv ctxt)))
                 (lvar-annotation
                  (lexenv-handled-conditions (lvar-annotation-lexenv ctxt)))
                 (compiler-error-context
                  (compiler-error-context-handled-conditions ctxt))
                 ;; Is this right? I would think that if lexenv is null
                 ;; we should look at *HANDLED-CONDITIONS*.
                 ((or ctran null) (lexenv-handled-conditions *lexenv*))))
             *handled-conditions*))
       (handle-p (condition type)
         #+sb-xc-host (cl:typep condition type) ; TYPE is a sexpr
         #-sb-xc-host (%%typep condition type))) ; TYPE is a CTYPE
  (declare (inline handle-p))

  (defun handle-condition-p (condition)
    (dolist (muffle (get-handled-conditions) nil)
      (destructuring-bind (type . restart-name) muffle
        (when (and (handle-p condition type)
                   (find-restart restart-name condition))
          (return t)))))

  (defun handle-condition-handler (condition)
    (let ((muffles (get-handled-conditions)))
      (aver muffles) ; FIXME: looks redundant with "fell through"
      (dolist (muffle muffles (bug "fell through"))
        (destructuring-bind (type . restart-name) muffle
          (when (handle-p condition type)
            (awhen (find-restart restart-name condition)
              (invoke-restart it)))))))

  ;; WOULD-MUFFLE-P is called (incorrectly) only by NOTE-UNDEFINED-REFERENCE.
  ;; It is not wrong per se, but as used, it is wrong, making it nearly
  ;; impossible to muffle a subset of undefind warnings whose NAME and KIND
  ;; slots match specific things tested by a user-defined predicate.
  ;; Attempting to do that might muffle everything, depending on how your
  ;; predicate responds to a vanilla WARNING. Consider e.g.
  ;;   (AND WARNING (NOT (SATISFIES HAIRYFN)))
  ;; where HAIRYFN depends on the :FORMAT-CONTROL and :FORMAT-ARGUMENTS.
  (defun would-muffle-p (condition)
    (let ((ctype (rassoc 'muffle-warning
                         (lexenv-handled-conditions *lexenv*))))
      (and ctype (handle-p condition (car ctype))))))

;;; Read all forms from INFO and compile them, with output to
;;; *COMPILE-OBJECT*. Return (VALUES ABORT-P WARNINGS-P FAILURE-P).
(defun sub-compile-file (info cfasl)
  (declare (type source-info info))
  (let ((*package* (sane-package))
        (*readtable* *readtable*)
        (*compile-file-pathname* nil) ; set by GET-SOURCE-STREAM
        (*compile-file-truename* nil) ; "
        (*policy* *policy*)
        (*macro-policy* *macro-policy*)

        (*compilation*
         (make-compilation
          :coverage-metadata (cons (make-hash-table :test 'equal)
                                   (make-hash-table :test 'equal))
          ;; Whether to emit msan unpoisoning code depends on the runtime
          ;; value of the feature, not "#+msan", because we can use the target
          ;; compiler to compile code for itself which isn't sanitized,
          ;; *or* code for another image which is sanitized.
          ;; And we can also cross-compile assuming msan.
          :msan-unpoison (member :msan sb-xc:*features*)
          :block-compile *block-compile-argument*
          :entry-points *entry-points-argument*
          :compile-toplevel-object cfasl))

        (*handled-conditions* *handled-conditions*)
        (*disabled-package-locks* *disabled-package-locks*)
        (*lexenv* (make-null-lexenv))
        (*allow-instrumenting* nil)
        (*compiler-error-bailout*
         (lambda (&optional error)
           (declare (ignore error))
           (return-from sub-compile-file (values t t t))))
        (*current-path* nil)
        (*gensym-counter* 0)
        (sb-impl::*eval-source-info* nil)
        (sb-impl::*eval-tlf-index* nil)
        (sb-impl::*eval-source-context* nil))
    (handler-case
        (handler-bind (((satisfies handle-condition-p) #'handle-condition-handler))
          (with-compilation-values
            (with-compilation-unit ()
                (setf (sb-fasl::fasl-output-source-info *compile-object*)
                      (debug-source-for-info info))
                (with-ir1-namespace
                  (do-forms-from-info ((form current-index) info
                                       'input-error-in-compile-file)
                    (with-source-paths
                      (find-source-paths form current-index)
                      (let ((*gensym-counter* 0))
                        (when *compile-print*
                          (note-top-level-form form))
                        (process-toplevel-form
                         form `(original-source-start 0 ,current-index) nil))))
                  (let ((*source-info* info))
                    (finish-block-compilation)))
                (let ((code-coverage-records
                       (code-coverage-records (coverage-metadata *compilation*))))
                  (unless (zerop (hash-table-count code-coverage-records))
                  ;; Dump the code coverage records into the fasl.
                   (with-source-paths
                    (fopcompile `(record-code-coverage
                                  ',(namestring *compile-file-pathname*)
                                  ',(let (list)
                                      (maphash (lambda (k v)
                                                 (declare (ignore k))
                                                 (push v list))
                                               code-coverage-records)
                                      list))
                                nil
                                nil))))
                nil)))
      ;; Some errors are sufficiently bewildering that we just fail
      ;; immediately, without trying to recover and compile more of
      ;; the input file.
      (fatal-compiler-error (condition)
       (signal condition)
       (fresh-line *error-output*)
       (pprint-logical-block (*error-output* nil :per-line-prefix "; ")
         (format *error-output*
                 "~@<~@:_compilation aborted because of fatal error: ~2I~_~A~@:_~:>"
                 (encapsulated-condition condition)))
       (finish-output *error-output*)
       (values t t t)))))

;;; Return a pathname for the named file. The file must exist.
(defun verify-source-file (pathname-designator)
  (let* ((pathname (pathname pathname-designator))
         (default-host (make-pathname :host (pathname-host pathname))))
    (flet ((try-with-type (path type error-p)
             (let ((new (merge-pathnames
                         path (make-pathname :type type
                                             :defaults default-host))))
               (if (probe-file new)
                   new
                   (and error-p (truename new))))))
      (cond ((typep pathname 'logical-pathname)
             (try-with-type pathname "LISP" t))
            ((probe-file pathname) pathname)
            ((try-with-type pathname "lisp"  nil))
            ((try-with-type pathname "lisp"  t))))))

(defun elapsed-time-to-string (internal-time-delta)
  (multiple-value-bind (tsec remainder)
      (truncate internal-time-delta internal-time-units-per-second)
    (let ((ms (truncate remainder (/ internal-time-units-per-second 1000))))
      (multiple-value-bind (tmin sec) (truncate tsec 60)
        (multiple-value-bind (thr min) (truncate tmin 60)
          (format nil "~D:~2,'0D:~2,'0D.~3,'0D" thr min sec ms))))))

;;; Print some junk at the beginning and end of compilation.
(defun print-compile-start-note (source-info)
  (declare (type source-info source-info))
  (let ((file-info (source-info-file-info source-info)))
    #+sb-xc-host
    (compiler-mumble "~&; ~Aing file ~S:~%"
                     (if sb-cold::*compile-for-effect-only* "load" "x-compil")
                     (namestring (file-info-pathname file-info)))
    #-sb-xc-host
    (compiler-mumble "~&; compiling file ~S (written ~A):~%"
                     (namestring (file-info-pathname file-info))
                     (format-universal-time nil
                                            (file-info-write-date file-info)
                                            :style :government
                                            :print-weekday nil
                                            :print-timezone nil)))
  (values))

(defun print-compile-end-note (source-info won)
  (declare (type source-info source-info))
  (compiler-mumble "~&; compilation ~:[aborted after~;finished in~] ~A~&"
                   won
                   (elapsed-time-to-string
                    (- (get-internal-real-time)
                       (source-info-start-real-time source-info))))
  (values))

;;; Open some files and call SUB-COMPILE-FILE. If something unwinds
;;; out of the compile, then abort the writing of the output file, so
;;; that we don't overwrite it with known garbage.
(defun compile-file
    (input-file
     &key

     ;; ANSI options
     (output-file "" output-file-p)
     ;; We rebind the specials despite such behavior not being mentioned
     ;; in CLHS. Several other lisp implementations do this as well.
     ((:verbose *compile-verbose*) *compile-verbose*)
     ((:print *compile-print*) *compile-print*)
     (external-format :default)

     ;; extensions
     ((:progress *compile-progress*) *compile-progress*)
     (trace-file nil)
     ((:block-compile *block-compile-argument*)
      *block-compile-default*)
     ((:entry-points *entry-points-argument*) nil)
     (emit-cfasl *emit-cfasl*))
  "Compile INPUT-FILE, producing a corresponding fasl file and
returning its filename.

  :PRINT
     If true, a message per non-macroexpanded top level form is printed
     to *STANDARD-OUTPUT*. Top level forms that whose subforms are
     processed as top level forms (eg. EVAL-WHEN, MACROLET, PROGN) receive
     no such message, but their subforms do.

     As an extension to ANSI, if :PRINT is :top-level-forms, a message
     per top level form after macroexpansion is printed to *STANDARD-OUTPUT*.
     For example, compiling an IN-PACKAGE form will result in a message about
     a top level SETQ in addition to the message about the IN-PACKAGE form'
     itself.

     Both forms of reporting obey the SB-EXT:*COMPILER-PRINT-VARIABLE-ALIST*.

  :BLOCK-COMPILE {NIL | :SPECIFIED | T}
     Determines whether multiple functions are compiled together as a unit,
     resolving function references at compile time.  NIL means that global
     function names are never resolved at compilation time.  :SPECIFIED means
     that names are resolved at compile-time when convenient (as in a
     self-recursive call), but the compiler doesn't combine top-level DEFUNs.
     With :SPECIFIED, an explicit START-BLOCK declaration will enable block
     compilation.  A value of T indicates that all forms in the file(s) should
     be compiled as a unit.  The default is the value of
     SB-EXT:*BLOCK-COMPILE-DEFAULT*, which is initially NIL.

  :ENTRY-POINTS
     This specifies a list of function names for functions in the file(s) that
     must be given global definitions.  This only applies to block
     compilation, and is useful mainly when :BLOCK-COMPILE T is specified on a
     file that lacks START-BLOCK declarations.  If the value is NIL (the
     default) then all functions will be globally defined.

  :TRACE-FILE
     If given, internal data structures are dumped to the specified
     file, or if a value of T is given, to a file of *.trace type
     derived from the input file name. (non-standard)

  :EMIT-CFASL
     (Experimental). If true, outputs the toplevel compile-time effects
     of this file into a separate .cfasl file."
  (%compile-files (list input-file) external-format output-file-p output-file
                  trace-file emit-cfasl))

(defun compile-files
    (inputs &key (output-file "" output-file-p)
                 ((:verbose *compile-verbose*) *compile-verbose*)
                 ((:print *compile-print*) *compile-print*)
                 (external-format :default)
                 ((:progress *compile-progress*) *compile-progress*)
                 (trace-file nil)
                 ((:block-compile *block-compile-argument*) *block-compile-default*)
                 ((:entry-points *entry-points-argument*) nil)
                 (emit-cfasl *emit-cfasl*))
  (%compile-files inputs external-format output-file-p output-file trace-file emit-cfasl))

(defun %compile-files (inputs external-format output-file-p output-file
                       trace-file emit-cfasl)
  (let* ((output-file-pathname nil)
         (fasl-output nil)
         (cfasl-pathname nil)
         (cfasl-output nil)
         (abort-p t)
         (warnings-p nil)
         (failure-p t) ; T in case error keeps this from being set later
         (input-pathname (verify-source-file (car inputs)))
         (source-infos
          (mapcar (lambda (file)
                    (make-file-source-info (verify-source-file file)
                                           external-format
                                           #-sb-xc-host t)) ; can't track, no SBCL streams
                  inputs))
         (*last-message-count* (list* 0 nil nil))
         (*last-error-context* nil)
         (*compiler-trace-output* nil)) ; might be modified below

    (unwind-protect
        (progn
          ;; To avoid passing "" as OUTPUT-FILE when unsupplied, we exploit the fact
          ;; that COMPILE-FILE-PATHNAME allows random &KEY args.
          (setq output-file-pathname
                (compile-file-pathname (car inputs)
                                       (when output-file-p :output-file) output-file)
                fasl-output (open-fasl-output output-file-pathname
                                              (namestring input-pathname)))
          (when emit-cfasl
            (setq cfasl-pathname (make-pathname :type "cfasl" :defaults output-file-pathname))
            (setq cfasl-output (open-fasl-output cfasl-pathname (namestring input-pathname))))
          (when trace-file
            (setf *compiler-trace-output*
                  (if (streamp trace-file)
                      trace-file
                      (open (merge-pathnames
                             (if (eql trace-file t) "" trace-file)
                             (make-pathname :type "trace" :defaults
                                            (fasl-output-stream fasl-output)))
                            :if-exists :supersede :direction :output))))

          (let ((*compile-object* fasl-output))
            (setf abort-p nil failure-p nil)
            (dolist (source-info source-infos)
              (multiple-value-bind (sub-abort-p sub-warnings-p sub-failure-p)
                  (sub-compile-file source-info cfasl-output)
                (setf abort-p (or abort-p sub-abort-p)
                      warnings-p (or warnings-p sub-warnings-p)
                      failure-p (or failure-p sub-failure-p))))))

      (mapc #'close-source-info source-infos)

      (when fasl-output
        (close-fasl-output fasl-output abort-p)
        ;; There was an assignment here
        ;;   (setq fasl-pathname (pathname (fasl-output-stream fasl-output)))
        ;; which seems pretty bogus, because we've computed the fasl-pathname,
        ;; and should return exactly what was computed so that it 100% agrees
        ;; with what COMPILE-FILE-PATHNAME said we would write into.
        ;; A distorted variation of the name coming from the stream is just wrong,
        ;; because do not support versioned pathnames.
        (when (and (not abort-p) *compile-verbose*)
          (compiler-mumble "~2&; wrote ~A~%" (namestring output-file-pathname))))

      (when cfasl-output
        (close-fasl-output cfasl-output abort-p)
        (when (and (not abort-p) *compile-verbose*)
          (compiler-mumble "; wrote ~A~%" (namestring cfasl-pathname))))

      (when *compile-verbose*
        (dolist (source-info source-infos)
          (print-compile-end-note source-info (not abort-p))))

      ;; Don't nuke stdout if you use :trace-file *standard-output*
      (when (and trace-file (not (streamp trace-file)))
        (close *compiler-trace-output*)))

    ;; CLHS says that the first value is NIL if the "file could not
    ;; be created". We interpret this to mean "a valid fasl could not
    ;; be created" -- which can happen if the compilation is aborted
    ;; before the whole file has been processed, due to eg. a reader
    ;; error.
    (values (when (and (not abort-p) output-file)
              ;; Again, more bogosity. Why do PROBE-FILE here
              ;; when it achieves nothing other than to potentially disagree
              ;; with what COMPILE-FILE-PATHNAME returned.
              ;; I would guess that the intent of the spec was to not return
              ;; pathnames with a wild version component, but it never anticipated
              ;; that content-addressable storage would be a thing.
              ;; Unfortunately there's no way to give lossless information here
              ;; while remaining ANSI-compliant. So let's repurpose the secret
              ;; *MERGE-PATHNAMES* option to return pathnames that don't suck.
              (or (and *merge-pathnames* (probe-file output-file-pathname))
                  output-file-pathname))
            warnings-p
            failure-p)))

;;; KLUDGE: Part of the ANSI spec for this seems contradictory:
;;;   If INPUT-FILE is a logical pathname and OUTPUT-FILE is unsupplied,
;;;   the result is a logical pathname. If INPUT-FILE is a logical
;;;   pathname, it is translated into a physical pathname as if by
;;;   calling TRANSLATE-LOGICAL-PATHNAME.
;;; So I haven't really tried to make this precisely ANSI-compatible
;;; at the level of e.g. whether it returns logical pathname or a
;;; physical pathname. Patches to make it more correct are welcome.
;;; -- WHN 2000-12-09
;;;
;;; Issues of logical-pathname handling aside, I checked some other lisps
;;; to see what they do with the following two examples:
;;;  (COMPILE-FILE "a/b/file.lisp :output-file "x/y/z/")
;;;  (COMPILE-FILE "a/b/file.lisp :output-file "x/y/out")
;;; and it turns out that they don't implement the spirit of the law,
;;; forget about the letter of the law. The spirit (intent) is that regardless
;;; of how pathnames are handled, COMPILE-FILE-PATHNAME should tell you exactly
;;; what pathname the compiler would write into given the input and output to
;;; COMPILE-FILE. But they can't even do that much correctly.
;;; So forget about how merging "should" work - it's a crap shoot at best.

;;; Clozure 1.10-r16196
;;; -------------------
;;; ? (COMPILE-FILE-PATHNAME "a/b/file.lisp" :output-file #p"x/y/z/")
;;;  => #P"a/b/x/y/z/file.lx64fsl" ; ok, so it thinks it merges input and output dirs
;;; let's confirm by actually compiling:
;;; ? (COMPILE-FILE "a/b/file.lisp" :output-file #p"x/y/z/")
;;; #P"/tmp/sbcl/x/y/z/file.lx64fsl" ; no, it didn't actually. it's what I want though
;;;
;;; ECL 16.1.3
;;; ----------
;;; (compile-file-pathname "a/b/file.lisp" :output-file #p"x/y/z/")
;;; #P"x/y/z/" ; ok, maybe it will do additional defaulting to get the name and type?
;;; (compile-file "a/b/file.lisp" :output-file #p"x/y/z/")
;;; Internal error:
;;;   ** Pathname without a physical namestring:
;;; Nope, it won't default them. However:
;;; (compile-file "a/b/file.lisp" :output-file #p"x/y/z/out")
;;; => #P"/tmp/sbcl/x/y/z/out"
;;; so it worked, but it failed to default the file type to '.fas'
;;; which it would have if nothing were specified.
;;;
;;; ABCL 1.7.1
;;; ----------
;;; (compile-file-pathname "a/b/file.lisp" :output-file #p"x/y/z/")
;;; #P"/tmp/sbcl/a/b/x/y/z/file.lisp" ; OK, so it says it merged input + output dirs
;;; but it didn't stick on a pathname-type. However
;;; (compile-file "a/b/file.lisp" :output-file #p"x/y/z/")
;;; ; Compiling /tmp/sbcl/a/b/file.lisp ...
;;; #<THREAD "interpreter" {E2B80EB}>: Debugger invoked on condition of type SIMPLE-ERROR
;;;   Pathname has no namestring:
;;; And now:
;;; (compile-file "a/b/file.lisp" :output-file #p"x/y/z/out.abcl")
;;; => #P"/tmp/sbcl/x/y/z/out.abcl" ; so it *didn't* actually merge dirs, which is fine
;;;
;;; But we try our best to give somewhat understandable semantics:
;;; * strongly prefer that all fasls have a pathname-type
;;;   whether or not the output was specified. However, if you are sadistic
;;;   (and/or enjoy being confusing to others), then :OUTPUT-FILE is permitted
;;;   to have :UNSPECIFIC as the type, and it will lack the '.fasl' suffix.
;;; * we can accept just a directory for the output (a namestring ending in "/"
;;;   on Unix) and will take the pathname-name from the input
;;; * we will never merge directories from the input to output
;;;
;;; It is unclear what should happen with
;;; (compile-file "sys:contrib;foo.lisp" :output-file "obj")
;;; Is "obj" on the logical host or the physical host?

(defun compile-file-pathname (input-file &key (output-file nil output-file-p)
                              &allow-other-keys)
  "Return a pathname describing what file COMPILE-FILE would write to given
   these arguments."
  ;; ANSI: The defaults for the OUTPUT-FILE are taken from the pathname
  ;; that results from merging the INPUT-FILE with the value of
  ;; *DEFAULT-PATHNAME-DEFAULTS*, except that the type component should
  ;; default to the appropriate implementation-defined default type for
  ;; compiled files.
   (let* ((input (pathname input-file))
          (output (if output-file-p (pathname output-file)))
          (host/dev/dir
           (if (or (not output) (memq (pathname-directory output) '(nil :unspecific)))
               input output)))
     ;; Merging *D-P-D* here is ridiculous, because every pathname is eventually
     ;; merged against it.
     ;; Users can set it to #P"" around calling this to obtain a lossless answer.
     (merge-pathnames
      (flet ((pick (slot default &aux (specified (if output (funcall slot output))))
               ;; :unspecific is left alone, "as if the field were 'filled'"
               ;; (http://www.lispworks.com/documentation/HyperSpec/Body/19_bbbca.htm)
               ;; which makes little to zero sense at all for the PATHNAME-NAME
               ;; of a fasl file, but is allowable for its PATHNAME-TYPE.
               (cond ((or (not specified)
                          (and (eq specified :unspecific) (eq slot 'pathname-name)))
                      default)
                     (t
                      specified))))
        (make-pathname :host (pathname-host host/dev/dir)
                       :device (pathname-device host/dev/dir)
                       :directory (pathname-directory host/dev/dir)
                       :name (pick 'pathname-name (pathname-name input))
                       :type (pick 'pathname-type *fasl-file-type*))))))

;;; FIXME: find a better place for this.
(defun always-boundp (name)
  (case (info :variable :always-bound name)
    (:always-bound t)
    ;; Compiling to fasl considers a symbol always-bound if its
    ;; :always-bound info value is now T or will eventually be T.
    (:eventually (producing-fasl-file))))
