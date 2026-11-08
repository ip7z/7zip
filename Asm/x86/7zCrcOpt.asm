; 7zCrcOpt.asm -- CRC32 calculation : optimized version
; 2023-12-08 : Igor Pavlov : Public domain

%include "7zAsm.inc"

MY_ASM_START

%define NUM_WORDS   3
%define UNROLL_CNT  2

%if (NUM_WORDS < 1) || (NUM_WORDS > 64)
    %fatal <NUM_WORDS_IS_INCORRECT>
%endif
%if UNROLL_CNT < 1
    %fatal <UNROLL_CNT_IS_INCORRECT>
%endif

%define rD      r2
%define rD_x    x2
%define rN      r7
%define rT      r5

%if XBITS == 32
    %if IS_CDECL == 1
        %define crc_OFFS    (REG_SIZE * 5)
        %define data_OFFS   (REG_SIZE + crc_OFFS)
        %define size_OFFS   (REG_SIZE + data_OFFS)
    %else
        %define size_OFFS   (REG_SIZE * 5)
    %endif
        %define table_OFFS  (REG_SIZE + size_OFFS)
%endif

; rN + rD is same speed as rD, but we reduce one instruction in loop
%define SRCDAT_1            rN + rD * 1 + 1 *
%define SRCDAT_4            rN + rD * 1 + 4 *


%macro CRC 4 ; op, dest, src, t
    %assign n %find(%3, x0,x1,x2,x3,x4,x5,x6,x7,x8,x9)
    %if n == 0
        %fatal <CRC_src_param_IS_INCORRECT>
    %else
        ; x<n>  ==>  r<n>
        %1      %2, [rT + %tok(%strcat('r', %eval(n-1))) * 4 + 0400h * (%4)]
    %endif
%endmacro

%macro CRC_XOR 3 ; dest, src, t
        CRC     xor, %1, %2, %3
%endmacro

%macro CRC_MOV 3 ; dest, src, t
        CRC     mov, %1, %2, %3
%endmacro

; movzx x0, x0_L - is slow in some cpus (ivb), if same register for src and dest
; movzx x3, x0_L sometimes is 0   cycles latency (not always)
; movzx x3, x0_L sometimes is 0.5 cycles latency
; movzx x3, x0_H is 2 cycles latency in some cpus

%macro CRC1b 0
        movzx   x6, byte [rD]
        MOVZXLO x3, x0
        inc     rD
        shr     x0, 8
        xor     x6, x3
        CRC_XOR x0, x6, 0
        dec     rN
%endmacro

%macro LOAD_1 4 ; dest, t, iter, index
        movzx   %1, byte [SRCDAT_1 (4 * (NUM_WORDS - 1 - %2 + %3 * NUM_WORDS) + %4)]
%endmacro

%macro LOAD_2 4 ; dest, t, iter, index
        movzx   %1, word [SRCDAT_1 (4 * (NUM_WORDS - 1 - %2 + %3 * NUM_WORDS) + %4)]
%endmacro

%macro CRC_QUAD 3 ; nn, t, iter
    %if XBITS == 64
        ; paired memory loads give 1-3% speed gain, but it uses more registers
        LOAD_2  x3, %2, %3, 0
        LOAD_2  x9, %2, %3, 2
        MOVZXLO x6, x3
        shr     x3, 8
        CRC_XOR %1, x6, %2 * 4 + 3
        MOVZXLO x6, x9
        shr     x9, 8
        CRC_XOR %1, x3, %2 * 4 + 2
        CRC_XOR %1, x6, %2 * 4 + 1
        CRC_XOR %1, x9, %2 * 4 + 0
    %elif 0
        LOAD_2  x3, %2, %3, 0
        MOVZXLO x6, x3
        shr     x3, 8
        CRC_XOR %1, x6, %2 * 4 + 3
        CRC_XOR %1, x3, %2 * 4 + 2
        LOAD_2  x3, %2, %3, 2
        MOVZXLO x6, x3
        shr     x3, 8
        CRC_XOR %1, x6, %2 * 4 + 1
        CRC_XOR %1, x3, %2 * 4 + 0
    %elif 0
        LOAD_1  x3, %2, %3, 0
        LOAD_1  x6, %2, %3, 1
        CRC_XOR %1, x3, %2 * 4 + 3
        CRC_XOR %1, x6, %2 * 4 + 2
        LOAD_1  x3, %2, %3, 2
        LOAD_1  x6, %2, %3, 3
        CRC_XOR %1, x3, %2 * 4 + 1
        CRC_XOR %1, x6, %2 * 4 + 0
    %else
        ; 32-bit load is better if there is only one read port (core2)
        ; but that code can be slower if there are 2 read ports (snb)
        mov     x3, dword [SRCDAT_1 (4 * (NUM_WORDS - 1 - %2 + %3 *  NUM_WORDS) + 0)]
        MOVZXLO x6, x3
        CRC_XOR %1, x6, %2 * 4 + 3
        MOVZXHI x6, x3
        shr     x3, 16
        CRC_XOR %1, x6, %2 * 4 + 2
        MOVZXLO x6, x3
        shr     x3, 8
        CRC_XOR %1, x6, %2 * 4 + 1
        CRC_XOR %1, x3, %2 * 4 + 0
    %endif
%endmacro


%define LAST  (4 * (NUM_WORDS - 1))

%macro CRC_ITER 3 ; qq, nn, iter
        mov     %2, [SRCDAT_4 (NUM_WORDS * (1 + %3))]

    %assign i 0
    %rep NUM_WORDS - 1
        CRC_QUAD %2, i, %3
        %assign i i+1
    %endrep

        MOVZXLO x6, %1
        mov     x3, %1
        shr     x3, 24
        CRC_XOR %2, x6, LAST + 3
        CRC_XOR %2, x3, LAST + 0
        ror     %1, 16
        MOVZXLO x6, %1
        shr     %1, 24
        CRC_XOR %2, x6, LAST + 1
    %if ((UNROLL_CNT & 1) == 1) && (%3 == (UNROLL_CNT - 1))
        CRC_MOV %1, %1, LAST + 2
        xor     %1, %2
    %else
        CRC_XOR %2, %1, LAST + 2
    %endif
%endmacro


; + 4 for prefetching next 4-bytes after current iteration
%define NUM_BYTES_LIMIT    (NUM_WORDS * 4 * UNROLL_CNT + 4)
%define ALIGN_MASK         3


MY_PROC AddNum(CrcUpdateT, NUM_WORDS * 4), 4
        MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
    %if XBITS == 64
        mov     x0, REG_ABI_PARAM_0_x   ; x0 = x1(win) / x7(linux)
        mov     rT, REG_ABI_PARAM_3     ; r5 = r9(win) / x1(linux)
        mov     rN, REG_ABI_PARAM_2     ; r7 = r8(win) / r2(linux)
        ; mov     rD, REG_ABI_PARAM_1     ; r2 = r2(win)
      %if ABI == LINUX
        mov     rD, REG_ABI_PARAM_1     ; r2 = r6
      %endif
    %else
      %if IS_CDECL == 1
        mov     x0, [r4 + crc_OFFS]
        mov     rD, [r4 + data_OFFS]
      %else
        mov     x0, REG_ABI_PARAM_0_x
      %endif
        mov     rN, [r4 + size_OFFS]
        mov     rT, [r4 + table_OFFS]
    %endif

        cmp     rN, NUM_BYTES_LIMIT + ALIGN_MASK
        jb      .crc_end
@@:
        test    rD_x, ALIGN_MASK    ; test    rD, ALIGN_MASK
        jz      @F
        CRC1b
        jmp     @B
@@:
        xor     x0, dword [rD]
        lea     rN, [rD + rN * 1 - (NUM_BYTES_LIMIT - 1)]
        sub     rD, rN

ALIGN 16
@@:
%assign unr_index 0
%rep UNROLL_CNT
    %if (unr_index & 1) == 0
        CRC_ITER x0, x1, unr_index
    %else
        CRC_ITER x1, x0, unr_index
    %endif
    %assign unr_index unr_index+1
%endrep

        add     rD, NUM_WORDS * 4 * UNROLL_CNT
        jnc     @B

%if 0
        ; byte verson
        add     rD, rN
        xor     x0, dword [rD]
        add     rN, NUM_BYTES_LIMIT - 1
%else
        ; 4-byte version
        add     rN, 4 * NUM_WORDS * UNROLL_CNT
        sub     rD, 4 * NUM_WORDS * UNROLL_CNT
@@:
        MOVZXLO x3, x0
        MOVZXHI x1, x0
        shr     x0, 16
        MOVZXLO x6, x0
        shr     x0, 8
        CRC_MOV x0, x0, 0
        CRC_XOR x0, x3, 3
        CRC_XOR x0, x1, 2
        CRC_XOR x0, x6, 1

        add     rD, 4
%if (NUM_WORDS * UNROLL_CNT) != 1
        jc      @F
        xor     x0, [SRCDAT_4 0]
        jmp     @B
@@:
%endif
        add     rD, rN
        add     rN, 4 - 1

%endif

        sub     rN, rD
.crc_end:
        test    rN, rN
        jz      .func_end
@@:
        CRC1b
        jnz     @B

.func_end:
        MY_POP_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
        MY_ENDP

