# interp-priv-2: the data TLB is not flushed when the effective load/store privilege changes because of an
# M->M trap or an M->M MRET while mstatus.MPRV=1.
# Priv. spec (mstatus.MPRV): "When MPRV=1, load and store memory addresses are translated and protected ...
# as though the current privilege mode were set to MPP." Traps to M set MPP=M; MRET sets MPP to U.
#
# Sv39 megapages (S-only, no U bit): VA 0x80000000.. identity, VA 0x80200000..0x803fffff -> PA 0x80000000..
# PA 0x80340000 holds A=0x1111; PA 0x80140000 (= translation of VA 0x80340000) holds B=0x2222.
# Exit code bitmask:
#   1 = case 1: inside an M->M trap handler (MPRV=1, MPP=M, so effective M = physical access), a load of
#       0x80340000 returned B through the stale S-mode translation instead of physical A.
#   2 = case 2: after an M->M MRET (MPRV=1, MPP=U, so effective U), a load of an S-only page did not fault
#       because a stale effective-M TLB entry was used.
    .section .text
    .globl _start
_start:
    li t0, 0x80340000
    li t1, 0x1111
    sd t1, 0(t0)
    li t0, 0x80140000
    li t1, 0x2222
    sd t1, 0(t0)
    li t0, 0x80100000                               # root page table
    li t1, ((0x80101000 >> 12) << 10) | 1
    sd t1, 16(t0)                                   # root[2] -> L1 table
    li t0, 0x80101000                               # L1 table
    li t1, ((0x80000000 >> 12) << 10) | 0xcf        # D|A|X|W|R|V (no U)
    sd t1, 0(t0)                                    # VA 0x80000000 -> PA 0x80000000
    sd t1, 8(t0)                                    # VA 0x80200000 -> PA 0x80000000
    li t0, (8 << 60) | (0x80100000 >> 12)
    csrw satp, t0
    sfence.vma
    la t0, mtrap
    csrw mtvec, t0
    li s2, 0
    li s9, 0                                        # number of traps seen
    # ---- case 1: MPRV=1, MPP=S; translated load, then a faulting load -> M->M trap (MPP <- M)
    li t0, (3 << 11)
    csrc mstatus, t0
    li t0, (1 << 11)
    csrs mstatus, t0                                # MPP = S
    li t0, (1 << 17)
    csrs mstatus, t0                                # MPRV = 1 (the CSR write flushes the data TLB)
    li t2, 0x80340000
    ld t3, 0(t2)                                    # effective S: reads B via translation (TLB entry installed)
    li t6, 0x1000
    ld t4, 0(t6)                                    # VA 0x1000 unmapped -> load page fault -> trap to M
    mv a0, t5                                       # value read inside the handler
    li t1, 0x1111
    beq a0, t1, 1f
    ori s2, s2, 1
1:  # ---- case 2: MPRV=1, MPP=M (effective M) installs an identity entry; MRET M->M => MPP=U => effective U
    li t0, (1 << 17)
    csrc mstatus, t0
    li t0, (3 << 11)
    csrs mstatus, t0                                # MPP = M
    li t0, (1 << 17)
    csrs mstatus, t0                                # MPRV = 1
    li t2, 0x80340000
    ld t3, 0(t2)                                    # effective M: physical A, identity TLB entry installed
    la t0, after_mret
    csrw mepc, t0
    li s9, 0
    mret                                            # stays in M; MPP <- U; MPRV stays 1 => effective U
after_mret:
    ld a1, 0(t2)                                    # effective U on an S-only page: must load-page-fault
    mv a2, s9
    li t0, (1 << 17)
    csrc mstatus, t0
    bnez s9, 2f                                     # faulted as required
    ori s2, s2, 2
2:  mv a3, s2
    slli t1, s2, 1                                  # halt with exit code = s2
    ori t1, t1, 1
    li t0, 0x40008000
    sd t1, 0(t0)
3:  j 3b

    .align 4
mtrap:                                              # M->M trap handler (MPRV still 1, MPP now M)
    addi s9, s9, 1
    li t2, 0x80340000
    ld t5, 0(t2)                                    # effective M: must read physical A (0x1111)
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    li t0, (1 << 17)
    csrc mstatus, t0                                # MPRV = 0
    li t0, (3 << 11)
    csrs mstatus, t0                                # return to M
    mret
