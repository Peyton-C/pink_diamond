// Swift-calling-convention trampolines for arm64.
// Swift ABI: indirect result in x8, `self` in x20, thrown error returned in x21 (must be zeroed first).
// Resilient (opaque) value arguments are passed indirectly, i.e. as pointers.

.text
.p2align 2

// void sonic_call_init(void *fn, void *result, uint64_t config0, uint64_t config1, void **error)
//   TransitionPlanner.init(configuration:) throws -> TransitionPlanner
//   Configuration is a 9-byte POD the callee takes by value in x0/x1, not indirectly.
.globl _sonic_call_init
_sonic_call_init:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x20, x21, [sp, #16]
    str     x4, [sp, #32]
    mov     x16, x0
    mov     x8, x1
    mov     x0, x2
    mov     x1, x3
    mov     x21, #0
    blr     x16
    ldr     x4, [sp, #32]
    str     x21, [x4]
    ldp     x20, x21, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

// void sonic_call_transition(void *fn, void *result, void *from, void *to, void *criteria,
//                            void *planner, void **error)
//   TransitionPlanner.transition(from:to:criteria:) throws -> Result<Transition, FailureReason>
.globl _sonic_call_transition
_sonic_call_transition:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x20, x21, [sp, #16]
    str     x6, [sp, #32]
    mov     x16, x0
    mov     x8, x1
    mov     x0, x2
    mov     x1, x3
    mov     x2, x4
    mov     x20, x5
    mov     x21, #0
    blr     x16
    ldr     x6, [sp, #32]
    str     x21, [x6]
    ldp     x20, x21, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret
