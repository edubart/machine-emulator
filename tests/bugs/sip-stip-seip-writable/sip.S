# interp-priv-4: S-mode can set sip.STIP and clear sip.SEIP.
# Priv. spec (sip/sie): "If implemented, SEIP is read-only in sip, and is set and cleared by the execution
# environment" and "If implemented, STIP is read-only in sip, and is set and cleared by the execution environment".
# Only SSIP is writable through sip.
# M delegates STI and SEI to S, enables STIE and SEIE, sets mip.SEIP itself (legal for M), then enters S with
# SIE=0. S tries "csrc sip, SEIP" and "csrs sip, STIP", then sets SIE and records which interrupts are taken.
# Spec-expected: only SEI is taken (s6 = 0x200).
# Exit code bitmask: 1 = STI taken (S set STIP), 2 = SEI not taken (S cleared SEIP), 64 = unexpected trap to M.
# Built with -DCONTROL the two sip writes are replaced by nops (control run: must exit 0).
    .section .text
    .globl _start
_start:
    la t0, mhandler
    csrw mtvec, t0
    la t0, shandler
    csrw stvec, t0
    li t0, 0x220
    csrw mideleg, t0          # delegate STI, SEI
    csrw mie, t0              # STIE, SEIE
    li t0, 0x200
    csrs mip, t0              # M-mode sets SEIP
    li t0, (3 << 11)
    csrc mstatus, t0
    li t0, (1 << 11)
    csrs mstatus, t0          # MPP = S
    la t0, s_entry
    csrw mepc, t0
    mret
s_entry:                      # S-mode, sstatus.SIE = 0
    li t0, 0x200
#ifdef CONTROL
    nop
#else
    csrc sip, t0              # must have no effect (SEIP is read-only in sip)
#endif
    li t0, 0x20
#ifdef CONTROL
    nop
#else
    csrs sip, t0              # must have no effect (STIP is read-only in sip)
#endif
    csrr s7, sip
    li s6, 0
    csrsi sstatus, 2          # SIE = 1: pending S interrupts are taken now
    nop
    nop
    nop
    ecall                     # to M: report

    .align 2
shandler:
    csrr t1, scause
    slli t1, t1, 1
    srli t1, t1, 1            # interrupt code
    li t2, 1
    sll t2, t2, t1
    or s6, s6, t2             # record the interrupt taken
    csrc sie, t2              # disable that source so it is not taken again
    sret

    .align 2
mhandler:                     # ecall from S (or anything unexpected): compute the result and halt
    csrr s8, mcause
    li a0, 0
    andi t0, s6, 0x20
    beqz t0, 1f
    ori a0, a0, 1
1:  andi t0, s6, 0x200
    bnez t0, 2f
    ori a0, a0, 2
2:  li t0, 9
    beq s8, t0, 3f
    ori a0, a0, 64            # unexpected trap
3:  mv a2, s6                 # interrupts taken
    mv a3, s7                 # sip as read by S after the writes
    mv a1, s8                 # final mcause
    slli t1, a0, 1
    ori t1, t1, 1
    li t0, 0x40008000
    sd t1, 0(t0)
4:  j 4b
