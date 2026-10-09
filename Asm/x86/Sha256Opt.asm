; Sha256Opt.asm -- SHA-256 optimized code for SHA-256 x86 hardware instructions
; 2024-06-16 : Igor Pavlov : Public domain

%include "7zAsm.inc"

MY_ASM_START


; we can use external SHA256_K_ARRAY defined in Sha256.c
; but we must guarantee that SHA256_K_ARRAY is aligned for 16-bytes

; extern SHA256_K_ARRAY
; %define .K_CONST SHA256_K_ARRAY


; jwasm-based assemblers for linux and linker from new versions of binutils
; can generate incorrect code for load [ARRAY + offset] instructions.
; 22.00: we load .K_CONST offset to (rTable) register to avoid jwasm+binutils problem 
        %define rTable  r0
        ; %define rTable  .K_CONST

%if XBITS == 64
        %define rNum        REG_ABI_PARAM_2
    %if ABI == WINDOWS
        %define LOCAL_SIZE  (16 * 2)
    %endif
%else
        %define rNum        r3
        %define LOCAL_SIZE  (16 * 1)
%endif

%define rState REG_ABI_PARAM_0
%define rData  REG_ABI_PARAM_1




%macro MY_PROLOG 0
    %if XBITS == 64
      %if ABI == WINDOWS
        movdqa  [r4 + 8], xmm6
        movdqa  [r4 + 8 + 16], xmm7
        sub     r4, LOCAL_SIZE + 8
        movdqa  [r4     ], xmm8
        movdqa  [r4 + 16], xmm9
      %endif
    %else ; x86
        push    r3
        push    r5
        mov     r5, r4
        %define NUM_PUSH_REGS  2
        %define PARAM_OFFSET   (REG_SIZE * (1 + NUM_PUSH_REGS))
      %if IS_CDECL == 1
        mov     rState, [r4 + PARAM_OFFSET]
        mov     rData,  [r4 + PARAM_OFFSET + REG_SIZE * 1]
        mov     rNum,   [r4 + PARAM_OFFSET + REG_SIZE * 2]
      %else ; fastcall
        mov     rNum,   [r4 + PARAM_OFFSET]
      %endif
        and     r4, -16
        sub     r4, LOCAL_SIZE
    %endif
%endmacro

%macro MY_EPILOG 0
    %if XBITS == 64
      %if ABI == WINDOWS
        movdqa  xmm8, [r4]
        movdqa  xmm9, [r4 + 16]
        add     r4, LOCAL_SIZE + 8
        movdqa  xmm6, [r4 + 8]
        movdqa  xmm7, [r4 + 8 + 16]
      %endif
    %else ; x86
        mov     r4, r5
        pop     r5
        pop     r3
    %endif
    MY_ENDP
%endmacro


%define msg_N       0
%define tmp_N       0
%define state0_N    2
%define state1_N    3
%define w_regs      4

%define msg         XMM_REG(msg_N)
%define tmp         XMM_REG(tmp_N)
%define state1_save xmm1
%define state0      XMM_REG(state0_N)
%define state1      XMM_REG(state1_N)


%if XBITS == 64
        %define state0_save  xmm8
        %define mask2        xmm9
%else
        %define state0_save  [r4]
        %define mask2        xmm0
%endif

%macro LOAD_MASK 0
        movdqa  mask2, [.Reverse_Endian_Mask]
%endmacro

%macro LOAD_W 1
        movdqu  XMM_REG(w_regs + %1), [rData + 16 * %1]
        pshufb  XMM_REG(w_regs + %1), mask2
%endmacro


; pre1 <= 4 && pre2 >= 1 && pre1 > pre2 && (pre1 - pre2) <= 1
%define pre1 3
%define pre2 2


%macro RND4 1
        movdqa  msg, [rTable + (%1) * 16]
        XMMOP   paddd, msg_N, (w_regs + ((%1 + 0) mod 4))
        sha256rnds2 state0, state1
        pshufd  msg, msg, 0eH

    %if (%1 >= (4 - pre1)) && (%1 < (16 - pre1))
        ; w4[0] = msg1(w4[-4], w4[-3])
        XMMOP  sha256msg1, (w_regs + ((%1 + pre1) mod 4)), (w_regs + ((%1 + pre1 - 3) mod 4))
    %endif

        sha256rnds2 state1, state0

    %if (%1 >= (4 - pre2)) && (%1 < (16 - pre2))
        XMMOP  movdqa,  tmp_N, (w_regs + ((%1 + pre2 - 1) mod 4))
        XMMOP  palignr, tmp_N, (w_regs + ((%1 + pre2 - 2) mod 4)), 4
        XMMOP  paddd,   (w_regs + ((%1 + pre2) mod 4)), tmp_N
        ; w4[0] = msg2(w4[0], w4[-1])
        XMMOP  sha256msg2, (w_regs + ((%1 + pre2) mod 4)), (w_regs + ((%1 + pre2 - 1) mod 4))
    %endif
%endmacro





%macro REVERSE_STATE 0
                               ; state0 ; dcba
                               ; state1 ; hgfe
        pshufd      tmp, state0, 01bH   ; abcd
        pshufd   state0, state1, 01bH   ; efgh
        movdqa   state1, state0         ; efgh
        punpcklqdq  state0, tmp         ; cdgh
        punpckhqdq  state1, tmp         ; abef
%endmacro


MY_PROC Sha256_UpdateBlocks_HW, 3
        MY_PROLOG

        lea     rTable, [.K_CONST]

        cmp     rNum, 0
        je      .end_c

        movdqu   state0, [rState]       ; dcba
        movdqu   state1, [rState + 16]  ; hgfe

        REVERSE_STATE
       
    %if XBITS == 64
        LOAD_MASK
    %endif

    align 16
    .nextBlock:
        movdqa  state0_save, state0
        movdqa  state1_save, state1

    %if XBITS == 32
        LOAD_MASK
    %endif

        LOAD_W 0
        LOAD_W 1
        LOAD_W 2
        LOAD_W 3

        %assign k 0
        %rep 16
          RND4 k
          %assign k k+1
        %endrep

        paddd   state0, state0_save
        paddd   state1, state1_save

        add     rData, 64
        sub     rNum, 1
        jnz     .nextBlock

        REVERSE_STATE

        movdqu  [rState], state0
        movdqu  [rState + 16], state1

    .end_c:
        MY_EPILOG




[section READONLY]

ALIGN 16
.Reverse_Endian_Mask db 3,2,1,0, 7,6,5,4, 11,10,9,8, 15,14,13,12

ALIGN 16
.K_CONST:
    DD 0428a2f98H, 071374491H, 0b5c0fbcfH, 0e9b5dba5H
    DD 03956c25bH, 059f111f1H, 0923f82a4H, 0ab1c5ed5H
    DD 0d807aa98H, 012835b01H, 0243185beH, 0550c7dc3H
    DD 072be5d74H, 080deb1feH, 09bdc06a7H, 0c19bf174H
    DD 0e49b69c1H, 0efbe4786H, 00fc19dc6H, 0240ca1ccH
    DD 02de92c6fH, 04a7484aaH, 05cb0a9dcH, 076f988daH
    DD 0983e5152H, 0a831c66dH, 0b00327c8H, 0bf597fc7H
    DD 0c6e00bf3H, 0d5a79147H, 006ca6351H, 014292967H
    DD 027b70a85H, 02e1b2138H, 04d2c6dfcH, 053380d13H
    DD 0650a7354H, 0766a0abbH, 081c2c92eH, 092722c85H
    DD 0a2bfe8a1H, 0a81a664bH, 0c24b8b70H, 0c76c51a3H
    DD 0d192e819H, 0d6990624H, 0f40e3585H, 0106aa070H
    DD 019a4c116H, 01e376c08H, 02748774cH, 034b0bcb5H
    DD 0391c0cb3H, 04ed8aa4aH, 05b9cca4fH, 0682e6ff3H
    DD 0748f82eeH, 078a5636fH, 084c87814H, 08cc70208H
    DD 090befffaH, 0a4506cebH, 0bef9a3f7H, 0c67178f2H

