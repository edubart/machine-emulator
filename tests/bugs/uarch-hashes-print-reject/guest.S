# Bare-metal guest: a manual yield that accepts an input (rx-accepted), a short loop, then a manual yield that
# rejects it (rx-rejected). The machine stays at the rejecting yield.
    .option norvc
    .globl _start
_start:
    li s0, 0x40008000                          # HTIF tohost
    li t0, (2 << 56) | (1 << 48) | (1 << 32)   # yield (dev 2), manual (cmd 1), reason rx-accepted
    sd t0, 0(s0)
    li t1, 5
1:  addi t1, t1, -1
    bnez t1, 1b
    li t0, (2 << 56) | (1 << 48) | (2 << 32)   # yield (dev 2), manual (cmd 1), reason rx-rejected
    sd t0, 0(s0)
2:  j 2b
