# interp-priv-3: minstret loses one count for every interrupt taken.
# minstret counts retired instructions; taking an interrupt retires nothing, but must not subtract either.
# Between the two minstret reads below exactly 10 instructions retire:
#   csrr s0 (1) + 3 x [ sw MSIP=1 in main (1) + handler: sw MSIP=0, mret (2) ]
# and 3 machine software interrupts are taken (one right after each "sw t1, 0(s2)").
# Exit code = number of lost counts = 10 - (s1 - s0) (expected 0).
    .section .text
    .globl _start
_start:
    la t0, mtrap
    csrw mtvec, t0
    li t0, (1 << 3)              # mie.MSIE
    csrw mie, t0
    li s2, 0x2000000             # CLINT msip (hart 0)
    li t1, 1
    csrsi mstatus, 8             # mstatus.MIE = 1
    .option push
    .option norvc
    csrr s0, minstret            # (1) returns the count of instructions retired before it
    sw t1, 0(s2)                 # (2) MSIP=1 -> MSI taken before the next instruction
    sw t1, 0(s2)                 # (5) MSIP=1 -> MSI
    sw t1, 0(s2)                 # (8) MSIP=1 -> MSI
    csrr s1, minstret            # counts the 10 instructions retired since (1), including (1)
    .option pop
    sub a0, s1, s0               # a0 = observed delta (expected 10)
    li t0, 10
    sub a1, t0, a0               # a1 = lost counts
    slli t1, a1, 1
    ori t1, t1, 1
    li t0, 0x40008000
    sd t1, 0(t0)                 # halt with exit code = lost counts
1:  j 1b

    .align 4
mtrap:                           # 2 retired instructions per interrupt
    .option push
    .option norvc
    sw zero, 0(s2)               # MSIP=0
    mret
    .option pop
