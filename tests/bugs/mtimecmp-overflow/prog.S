# interp-priv-5: mtimecmp is compared as mtimecmp*8192 (mod 2^64) against mcycle, so huge values wrap.
# Priv. spec: the machine timer interrupt is pending when mtime >= mtimecmp (unsigned 64-bit comparison).
# mtimecmp = 2^61 + 3: mtime would need ~2^61 ticks to reach it, so MTIP must stay clear while the program
# spins for ~60000 cycles (mtime ~ 7). The emulator computes (2^61 + 3) * 8192 mod 2^64 = 3 * 8192 and raises
# MTI at mtime = 3.
# Exit code: 1 if MTI was taken (a1 = mtime at the trap, a0 = mcause), 0 otherwise.
    .section .text
    .globl _start
_start:
    la t0, mtrap
    csrw mtvec, t0
    li t0, 0x2004000             # CLINT mtimecmp (hart 0)
    li t1, (1 << 61) + 3
    sd t1, 0(t0)
    li t0, (1 << 7)              # mie.MTIE
    csrw mie, t0
    csrsi mstatus, 8             # mstatus.MIE = 1
    li t2, 30000
1:  addi t2, t2, -1
    bnez t2, 1b
    li t0, 0x200bff8             # CLINT mtime
    ld a1, 0(t0)
    li a2, 0
    j done

    .align 4
mtrap:
    csrr a0, mcause
    li t0, 0x200bff8             # CLINT mtime
    ld a1, 0(t0)
    li a2, 1
done:
    slli t1, a2, 1
    ori t1, t1, 1
    li t0, 0x40008000
    sd t1, 0(t0)
2:  j 2b
