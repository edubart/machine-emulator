# Guest for log-step-automatic-yield (bare metal, linked at 0x80000000).
# Reads a mode word at 0x80001000, runs 8 loop iterations, then (mode 1 only) performs one HTIF automatic yield
# (progress), then spins forever incrementing a memory counter, so every mcycle changes the state.
#   mode 0: no yield (control)        mode 1: automatic yield strictly inside the first 64 mcycles
    .text
    .globl _start
_start:
    li s0, 0x40008000          # HTIF tohost
    li s1, 0x80001000          # data page
    ld s2, 0(s1)               # mode
    li t0, 0
    li t2, 8
1:  addi t0, t0, 1
    sd t0, 8(s1)
    blt t0, t2, 1b
    li t1, 1
    bne s2, t1, 2f
    li t3, (2 << 56) | (0 << 48) | (1 << 32)   # dev yield, cmd automatic, reason progress, data 0
    sd t3, 0(s0)
2:  addi t0, t0, 1
    sd t0, 16(s1)
    j 2b
