# Bare-metal guest: a short loop, ONE automatic yield (progress 50.0%), a short loop, halt(0).
    .option norvc
    .globl _start
_start:
    li s0, 0x40008000                                  # HTIF tohost
    li t1, 10
1:  addi t1, t1, -1
    bnez t1, 1b
    li t0, (2 << 56) | (0 << 48) | (1 << 32) | 500     # yield (dev 2), automatic (cmd 0), reason progress, 500
    sd t0, 0(s0)
    li t1, 10
2:  addi t1, t1, -1
    bnez t1, 2b
    li t0, 1                                           # halt, exit code 0
    sd t0, 0(s0)
3:  j 3b
