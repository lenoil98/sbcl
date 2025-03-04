;;; This file contains the ARM specific runtime stuff.
;;;
(in-package "SB-VM")

(defun machine-type ()
  "Return a string describing the type of the local machine."
  "ARM64")

(defun return-machine-address (scp)
  (context-register scp lr-offset))

;;;; "Sigcontext" access functions, cut & pasted from sparc-vm.lisp,
;;;; then modified for ARM.
;;;;
;;;; See also x86-vm for commentary on signed vs unsigned.

(define-alien-routine ("os_context_float_register_addr" context-float-register-addr)
  (* unsigned) (context (* os-context-t)) (index int))

(defun context-float-register (context index format)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (sap-ref-single sap 0))
      (double-float
       (sap-ref-double sap 0))
      (complex-single-float
       (complex (sap-ref-single sap 0)
                (sap-ref-single sap 4)))
      (complex-double-float
       (complex (sap-ref-double sap 0)
                (sap-ref-double sap 8))))))

(defun %set-context-float-register (context index format value)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (setf (sap-ref-single sap 0) value))
      (double-float
       (setf (sap-ref-double sap 0) value))
      (complex-single-float
       (locally
           (declare (type (complex single-float) value))
         (setf (sap-ref-single sap 0) (realpart value)
               (sap-ref-single sap 4) (imagpart value))))
      (complex-double-float
       (locally
           (declare (type (complex double-float) value))
         (setf (sap-ref-double sap 0) (realpart value)
               (sap-ref-double sap 8) (imagpart value)))))))

;;;; INTERNAL-ERROR-ARGS.

;;; Given a (POSIX) signal context, extract the internal error
;;; arguments from the instruction stream.
;;;
;;; See EMIT-ERROR-BREAK for the scheme
(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (let* ((pc (context-pc context))
         (instruction (sap-ref-32 pc 0))
         (trap-number (ldb (byte 8 5) instruction))
         (error-number (cond
                         ((>= trap-number sb-vm:error-trap)
                          (prog1
                              (- trap-number sb-vm:error-trap)
                            (setf trap-number sb-vm:error-trap)))
                         (t
                          (prog1 (sap-ref-8 pc 4)
                            (setf pc (sap+ pc 1))))))
         (first-arg (ldb (byte 8 13) instruction)))
    (declare (type system-area-pointer pc))
    (if (= trap-number invalid-arg-count-trap)
        (values #.(error-number-or-lose 'invalid-arg-count-error)
                '(#.arg-count-sc)
                trap-number)
        (let ((length (sb-kernel::error-length error-number)))
          (declare (type (unsigned-byte 8) length))
          (unless (or (= first-arg zr-offset)
                      (zerop length))
            (decf length))
          (setf pc (sap+ pc 4))
          (let ((args (loop repeat length
                            with index = 0
                            collect (sb-c:sap-read-var-integerf pc index))))
            (values error-number
                    (if (= first-arg zr-offset)
                        args
                        (cons (make-sc+offset sb-vm:descriptor-reg-sc-number first-arg)
                              args))
                    trap-number))))))

;;; Undo the effects of XEP-ALLOCATE-FRAME
;;; and point PC to FUNCTION
(defun context-call-function (context function &optional arg-count)
  (with-pinned-objects (function)
    (with-pinned-context-code-object (context)
      (let* ((fun-addr (get-lisp-obj-address function))
             (entry (+ (sap-ref-word (int-sap fun-addr)
                                     (- (ash simple-fun-self-slot word-shift)
                                        fun-pointer-lowtag))
                       (- (ash simple-fun-insts-offset word-shift)
                          fun-pointer-lowtag))))
        (when arg-count
          (setf (context-register context nargs-offset)
                (get-lisp-obj-address arg-count)))
        (setf (context-register context lexenv-offset) fun-addr
              (context-register context lr-offset) entry)
        (set-context-pc context entry)))))

#+darwin-jit
(progn
  (define-alien-routine jit-patch
    void
    (address unsigned)
    (value unsigned))

  (define-alien-routine jit-patch-code
    void
    (code unsigned)
    (value unsigned)
    (index unsigned))

  (define-alien-routine jit-patch-int
    void
    (address unsigned)
    (value int))

  (define-alien-routine jit-patch-uint
    void
    (address unsigned)
    (value unsigned-int))

  (define-alien-routine jit-patch-uchar
    void
    (address unsigned)
    (value unsigned-char))

  (define-alien-routine jit-memcpy
    void
    (dst (* char))
    (src (* char))
    (char signed))

  (defun (setf sap-ref-word-jit) (value sap offset)
    (jit-patch (+ (sap-int sap) offset) value))

  (defun (setf signed-sap-ref-32-jit) (value sap offset)
    (jit-patch-int (+ (sap-int sap) offset) value))

  (defun signed-sap-ref-32-jit (sap offset)
    (signed-sap-ref-32 sap offset))

  (defun (setf sap-ref-32-jit) (value sap offset)
    (jit-patch-uint (+ (sap-int sap) offset) value))

  (defun sap-ref-32-jit (sap offset)
    (sap-ref-32 sap offset))

  (defun (setf sap-ref-8-jit) (value sap offset)
    (jit-patch-uchar (+ (sap-int sap) offset) value))

  (defun (setf code-header-ref) (value code index)
    (with-pinned-objects (code value)
      (jit-patch-code (get-lisp-obj-address code)
                      (get-lisp-obj-address value)
                      index))
    value))
