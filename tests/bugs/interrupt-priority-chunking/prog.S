# Bare-metal program with partial interrupt delegation (interp-priv-1).
#   * mideleg = SSIP only (STI stays M-destined), mie = SSIE | STIE
#   * M-mode sets mip.SSIP and mip.STIP, then drops to U-mode with both interrupts pending and enabled.
#   * The emulator takes the delegated SSI first (to S), which clears SIE. The M-destined STI stays pending and
#     enabled (M-destined interrupts are always enabled below M).
#   * The S handler runs a ~600-instruction loop with no CSR access, then clears SSIP and returns.
#   * The M handler records the mcycle at which STI was taken (s4) and how much S work ran before it (s8).
# An implementation that re-samples interrupts every mcycle (uarch step, cm_run(mcycle+1)) takes STI one
# instruction into the S handler. The fast interpreter defers it to its next interrupt-sampling point
# (the csrci sip ~600 instructions later, or the next cm_run() boundary), so the state at a given mcycle
# depends on how the run was split.
    .section .text
    .globl _start
_start:
    la   t0, mtrap
    csrw mtvec, t0
    la   t0, strap
    csrw stvec, t0
    li   t0, (1<<1)                 # mideleg = SSIP only
    csrw mideleg, t0
    li   t0, (1<<1)|(1<<5)          # mie = SSIE | STIE
    csrw mie, t0
    li   t0, (3<<11)                # MPP = U
    csrc mstatus, t0
    la   t0, u_entry
    csrw mepc, t0
    li   s2, 0
    li   s3, 0
    li   s4, 0
    li   s5, 0
    li   t0, (1<<1)|(1<<5)          # mip.SSIP | mip.STIP (M-mode may write the S bits of mip)
    csrs mip, t0
    mret                            # -> U-mode; both interrupts pending and enabled

u_entry:                            # U-mode workload
    addi s2, s2, 1
    j    u_entry

    .align 4
strap:                              # S-mode handler (SSI)
    csrr s6, scause
    li   t1, 200
1:  addi s3, s3, 1                  # handler work: no CSR access, no interrupt-sampling point
    addi t1, t1, -1
    bnez t1, 1b
    csrci sip, 2                    # clear SSIP
    sret

    .align 4
mtrap:                              # M-mode handler (STI)
    csrr s7, mcause
    csrr s4, mcycle                 # when the M-destined interrupt was actually taken
    csrr s5, mepc
    mv   s8, s3                     # S-handler loop iterations executed before it was taken
    li   t0, (1<<5)
    csrc mip, t0                    # acknowledge STIP
    mret
