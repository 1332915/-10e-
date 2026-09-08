/* 最小 _start, 绕过 glibc __libc_start_main (避免 set_robust_list) */
/* ARM EABI 汇编 */
.text
.global _start
_start:
    /* ARM EABI: 栈顶布局是 argc, argv[0], argv[1]..., NULL, envp[0]..., NULL, auxv */
    /* sp 指向 argc */
    ldr r0, [sp]          /* r0 = argc */
    add r1, sp, #4        /* r1 = argv */
    add r2, r1, r0, lsl #2
    add r2, r2, #4        /* r2 = envp (跳过 argv + NULL) */

    /* 调用 main(argc, argv, envp) */
    bl main

    /* exit_group(main_ret) */
    mov r7, #248          /* __NR_exit_group */
    svc #0
    /* 不会返回 */
