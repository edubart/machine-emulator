    .section .text.start
    .globl _start
_start:
    la sp, _stack_top
    call driver_main
1:  j 1b
    .section .bss
    .align 12
_stack:
    .skip 0x8000
_stack_top:
