; XzCrc64Opt.asm -- CRC64 calculation : optimized version
; 2023-12-08 : Igor Pavlov : Public domain

%include "7zAsm.inc"

MY_ASM_START

%define NUM_WORDS  3

%if (NUM_WORDS < 1) || (NUM_WORDS > 64)
    %fatal <num_words_IS_INCORRECT>
%endif

%define NUM_SKIP_BYTES  ((NUM_WORDS - 2) * 4)


; ALIGN_MASK is 3 or 7 bytes alignment:
%define ALIGN_MASK      (7 - (NUM_WORDS & 1) * 4)


%macro CRC_1 5 ; op, dest, src, t, word_index
    %assign n %find(%3, x0,x1,x2,x3,x4,x5,x6,x7)
    %if n == 0
        %fatal <CRC_1_src_param_IS_INCORRECT>
    %else
        ; x<n>  ==>  x<n>_R
        %1      %2, [rT + %tok(%strcat('x', %eval(n-1), "_R")) * 8 + 0800h * (%4) + (%5) * 4]
    %endif
%endmacro


%if XBITS == 64

%define rD      r11
%define rN      r10
%define rT      r9


%macro CRC_OP 4
        CRC_1  %1, %2, %3, %4, 0
%endmacro

%macro CRC_XOR 3 ; dest, src, t
        CRC_OP  xor, %1, %2, %3
%endmacro

%macro CRC_MOV 3 ; dest, src, t
        CRC_OP  mov, %1, %2, %3
%endmacro

%macro CRC1b 0
        movzx   x6, byte [rD]
        inc     rD
        MOVZXLO x3, x0
        xor     x6, x3
        shr     r0, 8
        CRC_XOR r0, x6, 0
        dec     rN
%endmacro


%if NUM_WORDS == 1

%define src_rN_offset    4
; + 4 for prefetching next 4-bytes after current iteration
%define NUM_BYTES_LIMIT  (NUM_WORDS * 4 + 4)
%define SRCDAT4          DWORD [rN + rD * 1]

%macro XOR_NEXT 0
        mov     x1, [rD]
        xor     r0, r1
%endmacro

%else ; NUM_WORDS > 1

%define src_rN_offset    8
; + 8 for prefetching next 8-bytes after current iteration
%define NUM_BYTES_LIMIT  (NUM_WORDS * 4 + 8)

%macro XOR_NEXT 0
        xor     r0, QWORD [rD] ; 64-bit read, can be unaligned
%endmacro

; 32-bit or 64-bit
%macro LOAD_SRC_MULT4 2 ; dest, word_index
        mov     %1, [rN + rD * 1 + 4 * (%2) - src_rN_offset];
%endmacro

%endif


MY_PROC AddNum(XzCrc64UpdateT, NUM_WORDS * 4), 4
        MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11

        mov     r0, REG_ABI_PARAM_0   ; r0  <- r1 / r7
        mov     rD, REG_ABI_PARAM_1   ; r11 <- r2 / r6
        mov     rN, REG_ABI_PARAM_2   ; r10 <- r8 / r2
%if ABI == LINUX
        mov     rT, REG_ABI_PARAM_3   ; r9  <- r9 / r1
%endif

        cmp     rN, NUM_BYTES_LIMIT + ALIGN_MASK
        jb      .crc_end
@@:
        test    rD, ALIGN_MASK
        jz      @F
        CRC1b
        jmp     @B
@@:
        XOR_NEXT
        lea     rN, [rD + rN * 1 - (NUM_BYTES_LIMIT - 1)]
        sub     rD, rN
        add     rN, src_rN_offset

ALIGN 16
@@:

%if NUM_WORDS == 1
  
        mov     x1, x0
        shr     x1, 8
        MOVZXLO x3, x1
        MOVZXLO x2, x0
        shr     x1, 8
        shr     r0, 32
        xor     x0, SRCDAT4
        CRC_XOR r0, x2, 3
        CRC_XOR r0, x3, 2
        MOVZXLO x2, x1
        shr     x1, 8
        CRC_XOR r0, x2, 1
        CRC_XOR r0, x1, 0

%else ; NUM_WORDS > 1

%if NUM_WORDS != 2
  %assign k 2

  %rep NUM_WORDS
    %if k == NUM_WORDS
        %exitrep
    %endif

        LOAD_SRC_MULT4  x1, k
        %define crc_op1  xor

    %if k == 2
      %if (NUM_WORDS & 1)
        LOAD_SRC_MULT4  x7, NUM_WORDS       ; aligned 32-bit
        LOAD_SRC_MULT4  x6, NUM_WORDS + 1   ; aligned 32-bit
        shl     r6, 32
      %else
        LOAD_SRC_MULT4  r6, NUM_WORDS       ; aligned 64-bit
        %undef  crc_op1
        %define crc_op1  mov
      %endif
    %endif
        %assign table  (4 * (NUM_WORDS - 1 - k))
        MOVZXLO x3, x1
        CRC_OP  crc_op1, r7, x3, 3 + table
        MOVZXHI x3, x1
        shr     x1, 16
        CRC_XOR r6, x3, 2 + table
        MOVZXLO x3, x1
        shr     x1, 8
        CRC_XOR r7, x3, 1 + table
        CRC_XOR r6, x1, 0 + table
        %assign k k+1
  %endrep
        %define crc_op2  xor

%else ; NUM_WORDS == 2
        LOAD_SRC_MULT4   r6, NUM_WORDS       ; aligned 64-bit
        %define crc_op2  mov
%endif ; NUM_WORDS == 2

        MOVZXHI x3, x0
        MOVZXLO x2, x0
        mov     r1, r0
        shr     r1, 32
        shr     x0, 16
        CRC_XOR r6, x2, NUM_SKIP_BYTES + 7
        CRC_OP  crc_op2, r7, x3, NUM_SKIP_BYTES + 6
        MOVZXLO x2, x0
        MOVZXHI x5, x1
        MOVZXLO x3, x1
        shr     x0, 8
        shr     x1, 16
        CRC_XOR r7, x2, NUM_SKIP_BYTES + 5
        CRC_XOR r6, x3, NUM_SKIP_BYTES + 3
        CRC_XOR r7, x0, NUM_SKIP_BYTES + 4
        CRC_XOR r6, x5, NUM_SKIP_BYTES + 2
        MOVZXLO x2, x1
        shr     x1, 8
        CRC_XOR r7, x2, NUM_SKIP_BYTES + 1
        CRC_MOV r0, x1, NUM_SKIP_BYTES + 0
        xor     r0, r6
        xor     r0, r7

%endif ; NUM_WORDS > 1
        add     rD, NUM_WORDS * 4
        jnc     @B

        sub     rN, src_rN_offset
        add     rD, rN
        XOR_NEXT
        add     rN, NUM_BYTES_LIMIT - 1
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



%else
; ==================================================================
; x86 (32-bit)

%define rD    r7
%define rN    r1
%define rT    r5

%define xA    x6
%define xA_R  r6

%if XBITS == 64
    %define num_VAR  r8
%else
    %define crc_OFFS  (REG_SIZE * 5)

  %if (IS_CDECL == 1) || (ABI == LINUX)
    ; cdecl or (GNU fastcall) stack:
    ;   (UInt32 *) table
    ;   size_t     size
    ;   void *     data
    ;   (UInt64)   crc
    ;   ret-ip <-(r4)
    %define data_OFFS   (8 + crc_OFFS)
    %define size_OFFS   (REG_SIZE + data_OFFS)
    %define table_OFFS  (REG_SIZE + size_OFFS)
    %define num_VAR     [r4 + size_OFFS]
    %define table_VAR   [r4 + table_OFFS]
  %else
    ; Windows fastcall:
    ;   r1 = data, r2 = size
    ; stack:
    ;   (UInt32 *) table
    ;   (UInt64)   crc
    ;   ret-ip <-(r4)
    %define table_OFFS  (8 + crc_OFFS)
    %define table_VAR   [r4 + table_OFFS]
    %define num_VAR     table_VAR
  %endif
%endif

%define SRCDAT4  DWORD [rN + rD * 1]

%macro CRC 6 ; op0, op1, dest0, dest1, src, t
        CRC_1   %1, %3, %5, %6, 0
        CRC_1   %2, %4, %5, %6, 1
%endmacro

%macro CRC_XOR 4 ; dest0, dest1, src, t
        CRC xor, xor, %1, %2, %3, %4
%endmacro


%macro CRC1b 0
        movzx   xA, BYTE [rD]
        inc     rD
        MOVZXLO x3, x0
        xor     xA, x3
        shrd    x0, x2, 8
        shr     x2, 8
        CRC_XOR x0, x2, xA, 0
        dec     rN
%endmacro


%macro MY_PROLOG_BASE 0
        MY_PUSH_4_REGS
  %if XBITS == 64
        mov     r0, REG_ABI_PARAM_0     ; r0 <- r1 / r7
        mov     rT, REG_ABI_PARAM_3     ; r5 <- r9 / r1
        mov     rN, REG_ABI_PARAM_2     ; r1 <- r8 / r2
        mov     rD, REG_ABI_PARAM_1     ; r7 <- r2 / r6
        mov     r2, r0
        shr     r2, 32
        mov     x0, x0
  %else
    %if (IS_CDECL == 1) || (ABI == LINUX)
        %assign proc_numParams  proc_numParams + 2 ; for ABI_LINUX
        mov     rN, [r4 + size_OFFS]
        mov     rD, [r4 + data_OFFS]
    %else
        mov     rD, REG_ABI_PARAM_0     ; r7 <- r1 : (data)
        mov     rN, REG_ABI_PARAM_1     ; r1 <- r2 : (size)
    %endif
        mov     x0, [r4 + crc_OFFS]
        mov     x2, [r4 + crc_OFFS + 4]
        mov     rT, table_VAR
  %endif
%endmacro


%macro MY_EPILOG_BASE 0
.crc_end:
        test    rN, rN
        jz      %%func_end
@@:
        CRC1b
        jnz     @B
%%func_end:
    %if XBITS == 64
        shl     r2, 32
        xor     r0, r2
    %endif
        MY_POP_4_REGS
%endmacro


%if NUM_WORDS == 1

%define NUM_BYTES_LIMIT_T4  (NUM_WORDS * 4 + 4)

MY_PROC AddNum(XzCrc64UpdateT, NUM_WORDS * 4), 5
        MY_PROLOG_BASE

        cmp     rN, NUM_BYTES_LIMIT_T4 + ALIGN_MASK
        jb      .crc_end
@@:
        test    rD, ALIGN_MASK
        jz      @F
        CRC1b
        jmp     @B
@@:
        xor     x0, [rD]
        lea     rN, [rD + rN * 1 - (NUM_BYTES_LIMIT_T4 - 1)]
        sub     rD, rN
        add     rN, 4

        MOVZXLO xA, x0
ALIGN 16
@@:
        mov     x3, SRCDAT4
        xor     x3, x2
        shr     x0, 8
        CRC xor, mov, x3, x2, xA, 3
        MOVZXLO xA, x0
        shr     x0, 8
        ; MOVZXHI  xA, x0
        ; shr     x0, 16
        CRC_XOR x3, x2, xA, 2

        MOVZXLO xA, x0
        shr     x0, 8
        CRC_XOR x3, x2, xA, 1
        CRC_XOR x3, x2, x0, 0
        MOVZXLO xA, x3
        mov     x0, x3

        add     rD, 4
        jnc     @B

        sub     rN, 4
        add     rD, rN
        xor     x0, [rD]
        add     rN, NUM_BYTES_LIMIT_T4 - 1
        sub     rN, rD

        MY_EPILOG_BASE
        MY_ENDP

%else ; NUM_WORDS > 1


%macro ITER_1 4
        MOVZXLO xA, %3
        shr     %3, 8
        CRC_XOR %1, %2, xA, %4
%endmacro


%macro ITER_4 4 ; v0, v1, a, off
    %if 0 == 0
        ITER_1  %1, %2, %3, %4 + 3
        ITER_1  %1, %2, %3, %4 + 2
        ITER_1  %1, %2, %3, %4 + 1
        CRC_XOR %1, %2, %3, %4
    %elif 0 == 0
        MOVZXLO xA, %3
        CRC_XOR %1, %2, xA, %4 + 3
        mov     xA, %3
        ror     %3, 16   ; 32-bit ror
        shr     xA, 24
        CRC_XOR %1, %2, xA, %4
        movzx   xA, %3
        shr     %3, 24
        CRC_XOR %1, %2, xA, %4 + 1
        CRC_XOR %1, %2, %3, %4 + 2
    %else
        ; MOVZXHI provides smaller code, but MOVZX_HI_BYTE is not fast instruction
        MOVZXLO xA, %3
        CRC_XOR %1, %2, xA, %4 + 3
        MOVZXHI xA, %3
        shr     %3, 16
        CRC_XOR %1, %2, xA, %4 + 2
        MOVZXLO xA, %3
        shr     %3, 8
        CRC_XOR %1, %2, xA, %4 + 1
        CRC_XOR %1, %2, %3, %4
    %endif
%endmacro


%macro ITER_1_PAIR 5 ; v0, v1, a0, a1, off
        ITER_1 %1, %2, %3, %5 + 4
        ITER_1 %1, %2, %4, %5
%endmacro

%define src_rD_offset  8
%define STEP_SIZE      (NUM_WORDS * 4)

%macro ITER_12_NEXT 4 ; op, index, v0, v1
        %1     %3, DWORD [rD + (%2 + 1) * STEP_SIZE     - src_rD_offset]
        %1     %4, DWORD [rD + (%2 + 1) * STEP_SIZE + 4 - src_rD_offset]
%endmacro

%macro ITER_12 5 ; index, a0, a1, v0, v1
  %if NUM_SKIP_BYTES == 0
        ITER_12_NEXT mov, %1, %4, %5
  %else
    %assign k 0
    %rep NUM_SKIP_BYTES
        movzx   xA, BYTE [rD + %1 * STEP_SIZE + k + 8 - src_rD_offset]
      %if k == 0
        CRC mov, mov,   %4, %5, xA, NUM_SKIP_BYTES - 1 - k
      %else
        CRC_XOR         %4, %5, xA, NUM_SKIP_BYTES - 1 - k
      %endif
      %assign k k+1
    %endrep
        ITER_12_NEXT xor, %1, %4, %5
  %endif

  %if 0 == 0
        ITER_4  %4, %5, %2, NUM_SKIP_BYTES + 4
        ITER_4  %4, %5, %3, NUM_SKIP_BYTES
  %else ; interleave version is faster/slower for different processors
        ITER_1_PAIR %4, %5, %2, %3, NUM_SKIP_BYTES + 3
        ITER_1_PAIR %4, %5, %2, %3, NUM_SKIP_BYTES + 2
        ITER_1_PAIR %4, %5, %2, %3, NUM_SKIP_BYTES + 1
        CRC_XOR     %4, %5, %2,     NUM_SKIP_BYTES + 4
        CRC_XOR     %4, %5, %3,     NUM_SKIP_BYTES
  %endif
%endmacro

; we use (UNROLL_CNT > 1) to reduce read ports pressure (num_VAR reads)
%define UNROLL_CNT           (2 * 1)
%define NUM_BYTES_LIMIT      (STEP_SIZE * UNROLL_CNT + 8)

MY_PROC AddNum(XzCrc64UpdateT, NUM_WORDS * 4), 5
        MY_PROLOG_BASE

        cmp     rN, NUM_BYTES_LIMIT + ALIGN_MASK
        jb      .crc_end
@@:
        test    rD, ALIGN_MASK
        jz      @F
        CRC1b
        jmp     @B
@@:
        xor     x0, [rD]
        xor     x2, [rD + 4]
        add     rD, src_rD_offset
        lea     rN, [rD + rN * 1 - (NUM_BYTES_LIMIT - 1)]
        mov     num_VAR, rN

ALIGN 16
@@:
    %assign i 0
    %rep UNROLL_CNT
      %if (i & 1) == 0
        ITER_12    i, x0, x2, x1, x3
      %else
        ITER_12    i, x1, x3, x0, x2
      %endif
      %assign i i+1
    %endrep

    %if (UNROLL_CNT & 1)
        mov     x0, x1
        mov     x2, x3
    %endif
        add     rD, STEP_SIZE * UNROLL_CNT
        cmp     rD, num_VAR
        jb      @B

        mov     rN, num_VAR
        add     rN, NUM_BYTES_LIMIT - 1
        sub     rN, rD
        sub     rD, src_rD_offset
        xor     x0, [rD]
        xor     x2, [rD + 4]

        MY_EPILOG_BASE
        MY_ENDP

%endif ; (NUM_WORDS > 1)
%endif ; ! x64

