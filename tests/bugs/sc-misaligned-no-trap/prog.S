# interp-isa-1: a misaligned SC.W/SC.D does not raise an exception; it just fails with rd=1.
# Unprivileged ISA (Zalrsc): for LR/SC, "If the address is not naturally aligned, an address-misaligned exception
# or an access-fault exception will be generated." So every SC below must trap (mcause 6 or 7).
# The trap handler counts traps in s0, records the last mcause in s1 and skips the faulting instruction.
# Exit code bitmask: 1 = sc.w at buf+1 (no reservation) did not trap,
#                    2 = sc.d at buf+4 after lr.d on the aligned buf did not trap,
#                    4 = sc.d at buf+6 (no reservation) did not trap,
#                    8 = control: misaligned lr.w did not trap (test itself broken)
    .section .text
    .globl _start
_start:
    la t0, handler
    csrw mtvec, t0
    li s0, 0
    la s3, buf
    li a7, 0                    # failure bitmask
    # T1: sc.w at buf+1, no reservation outstanding
    mv t1, s0
    addi t2, s3, 1
    li a3, 0x55
    sc.w a3, a3, (t2)
    bne s0, t1, 1f
    ori a7, a7, 1
1:  # T2: valid reservation on buf, then sc.d at buf+4 (misaligned for a doubleword)
    lr.d t3, (s3)
    mv t1, s0
    addi t2, s3, 4
    li a4, 0x66
    sc.d a4, a4, (t2)
    bne s0, t1, 2f
    ori a7, a7, 2
2:  # T3: sc.d at buf+6, no reservation outstanding
    mv t1, s0
    addi t2, s3, 6
    li a5, 0x77
    sc.d a5, a5, (t2)
    bne s0, t1, 3f
    ori a7, a7, 4
3:  # Control T4: lr.w at buf+2 must trap (it does)
    mv t1, s0
    addi t2, s3, 2
    lr.w a6, (t2)
    bne s0, t1, 4f
    ori a7, a7, 8
4:  mv a0, a7
    mv a1, s0                   # number of traps
    mv a2, s1                   # last mcause
    slli t1, a7, 1
    ori t1, t1, 1
    li t0, 0x40008000
    sd t1, 0(t0)
5:  j 5b

    .align 2
handler:
    addi s0, s0, 1
    csrr s1, mcause
    csrr s2, mtval
    csrr t6, mepc
    addi t6, t6, 4              # LR/SC are always 4-byte instructions
    csrw mepc, t6
    mret

    .align 4
buf: .dword 0x1111111111111111, 0x2222222222222222
