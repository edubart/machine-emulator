# interp-isa-2: page-table walks that violate a PMA raise a page fault instead of an access fault, and a
# required A/D write-back to a read-only PTE silently does nothing (the access succeeds).
# Privileged spec, Sv39 translation:
#   "If accessing pte violates a PMA or PMP check, raise an access-fault exception corresponding to the original
#    access type." and, for hardware A/D updating, "If a store to pte would violate a PMA or PMP check, raise an
#    access-fault exception corresponding to the original access type."
# Layout: root page table in RAM.
#   root[1] (VA 0x40000000) = non-leaf PTE -> PA 0x02000000 (CLINT, an I/O device, not memory)
#   root[3] (VA 0xC0000000) = non-leaf PTE -> PA 0x80000000000000 (read-only flash drive); flash[0] = leaf megapage
#                             -> RAM 0x80000000, R|W|V with A=0, D=0 (the A/D update needs a store to read-only memory)
# Loads and stores run in M-mode with MPRV=1, MPP=S; the fetch runs in S-mode.
# Results: a2..a6 = mcause observed (0 = no trap), s3 = flash PTE after the accesses.
# Exit code bitmask (spec-expected cause in parentheses):
#   1 = load via CLINT PTE != 5, 2 = store via CLINT PTE != 7, 4 = fetch via CLINT PTE != 1,
#   8 = load needing an A update in the read-only PTE != 5, 16 = store needing A/D updates in the read-only PTE != 7
    .equ FLASH, 0x80000000000000
    .section .text
    .globl _start
_start:
    la t0, handler
    csrw mtvec, t0
    la t0, root
    srli t0, t0, 12
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0            # Sv39, root page table
    sfence.vma
    li a7, 0
    li t3, 0x40000000        # VA1
    li t4, 0xC0000000        # VA2 (+ offset of buf in RAM)
    la t0, buf
    li t1, 0x80000000
    sub t0, t0, t1
    add t4, t4, t0
# T1: load via VA1 (PTE read from CLINT)
    li s1, 0
    la s4, 1f
    call mprv_s
    ld t0, 0(t3)
1:  call mprv_off
    mv a2, s1
    li t0, 5
    beq a2, t0, 1f
    ori a7, a7, 1
1:
# T2: store via VA1
    li s1, 0
    la s4, 1f
    call mprv_s
    sd zero, 0(t3)
1:  call mprv_off
    mv a3, s1
    li t0, 7
    beq a3, t0, 1f
    ori a7, a7, 2
1:
# T3: load via VA2 (leaf PTE in read-only flash with A=0)
    li s1, 0
    la s4, 1f
    call mprv_s
    ld t0, 0(t4)
1:  call mprv_off
    mv a5, s1
    li t0, 5
    beq a5, t0, 1f
    ori a7, a7, 8
1:
# T4: store via VA2 (needs A and D)
    li s1, 0
    la s4, 1f
    call mprv_s
    li t0, 0x1234
    sd t0, 0(t4)
1:  call mprv_off
    mv a6, s1
    li t0, 7
    beq a6, t0, 1f
    ori a7, a7, 16
1:
    li t0, FLASH
    ld s3, 0(t0)             # leaf PTE as stored in read-only flash (A = bit 6, D = bit 7)
# T5: instruction fetch at VA1 from S-mode
    li s1, 0
    la s4, 1f
    li t0, (3 << 11)
    csrc mstatus, t0
    li t0, (1 << 11)
    csrs mstatus, t0         # MPP = S
    csrw mepc, t3
    mret
1:  mv a4, s1
    li t0, 1
    beq a4, t0, 1f
    ori a7, a7, 4
1:
    mv a0, a7
    slli a1, a0, 1
    ori a1, a1, 1
    li t0, 0x40008000
    sd a1, 0(t0)
9:  j 9b

mprv_s:                      # MPRV=1, MPP=S
    li t0, (3 << 11)
    csrc mstatus, t0
    li t0, (1 << 11) | (1 << 17)
    csrs mstatus, t0
    ret
mprv_off:
    li t0, (1 << 17)
    csrc mstatus, t0
    ret

    .align 2
handler:                     # record mcause in s1, resume at s4 in M-mode
    csrr s1, mcause
    csrr s2, mtval
    csrw mepc, s4
    li t6, (3 << 11)
    csrs mstatus, t6         # MPP = M
    mret

    .align 12
root:
    .dword 0
    .dword (0x2000000 >> 12 << 10) | 1          # root[1]: non-leaf -> CLINT
    .dword (0x80000000 >> 12 << 10) | 0xcf      # root[2]: gigapage identity RWX AD (not used by the tests)
    .dword (FLASH >> 12 << 10) | 1              # root[3]: non-leaf -> read-only flash
    .fill 508, 8, 0
buf: .dword 0x1111111111111111
