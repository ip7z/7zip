; Sha1Opt.asm -- SHA-1 optimized code for SHA-1 x86 hardware instructions
; 2024-06-16 : Igor Pavlov : Public domain

%include "7zAsm.inc"

MY_ASM_START


%if XBITS == 64
        %define rNum        REG_ABI_PARAM_2
  %if ABI == WINDOWS
        %define LOCAL_SIZE  (16 * 2)
  %endif
%else
        %define rNum        r0
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
      %if IS_CDECL == 1
        mov     rState, [r4 + REG_SIZE * 1]
        mov     rData,  [r4 + REG_SIZE * 2]
        mov     rNum,   [r4 + REG_SIZE * 3]
      %else ; fastcall
        mov     rNum,   [r4 + REG_SIZE * 1]
      %endif
        push    r5
        mov     r5, r4
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
    %endif
        MY_ENDP
%endmacro


%define e0_N        0
%define e1_N        1
%define abcd_N      2
%define e0_save_N   3
%define w_regs      4

%define e0          XMM_REG(e0_N)
%define e1          XMM_REG(e1_N)
%define abcd        XMM_REG(abcd_N)
%define e0_save     XMM_REG(e0_save_N)


%if XBITS == 64
  %define abcd_save   xmm8
  %define mask2       xmm9
%else
  %define abcd_save   [r4]
  %define mask2       e1
%endif

%macro LOAD_MASK 0
        movdqa  mask2, [.Reverse_Endian_Mask]
%endmacro

%macro LOAD_W 1
        movdqu  XMM_REG(w_regs + %1), [rData + 16 * %1]
        pshufb  XMM_REG(w_regs + %1), mask2
%endmacro


; pre2 can be 2 or 3 (recommended)
%define pre2 3
%define pre1 (pre2 + 1)

%define NUM_ROUNDS4 20


%macro RND4 1
        XMMOP  movdqa, (e0_N + ((%1 + 1) mod 2)), abcd_N
        XMMOP  sha1rnds4, abcd_N, (e0_N + (%1 mod 2)), %1 / 5

        %assign nextM w_regs + ((%1 + 1) mod 4)

    %if (%1 == NUM_ROUNDS4 - 1)
        %assign nextM e0_save_N
    %endif

        XMMOP  sha1nexte, (e0_N + ((%1 + 1) mod 2)), nextM

    %if (%1 >= (4 - pre2)) && (%1 < (NUM_ROUNDS4 - pre2))
        XMMOP  pxor, (w_regs + ((%1 + pre2) mod 4)), (w_regs + ((%1 + pre2 - 2) mod 4))
    %endif

    %if (%1 >= (4 - pre1)) && (%1 < (NUM_ROUNDS4 - pre1))
        XMMOP  sha1msg1, (w_regs + ((%1 + pre1) mod 4)), (w_regs + ((%1 + pre1 - 3) mod 4))
    %endif

    %if (%1 >= (4 - pre2)) && (%1 < (NUM_ROUNDS4 - pre2))
        XMMOP  sha1msg2, (w_regs + ((%1 + pre2) mod 4)), (w_regs + ((%1 + pre2 - 1) mod 4))
    %endif
%endmacro


%macro REVERSE_STATE 0
                              ; abcd   ; dcba
                              ; e0     ; 000e
        pshufd  abcd, abcd, 1BH        ; abcd
        pshufd    e0, e0,   1BH        ; e000
%endmacro




MY_PROC Sha1_UpdateBlocks_HW, 3
        MY_PROLOG

        cmp     rNum, 0
        je      .end_c

        movdqu  abcd, [rState]           ; dcba
        movd    e0, dword [rState + 16]  ; 000e

        REVERSE_STATE

        %if XBITS == 64
        LOAD_MASK
        %endif


    ALIGN   16
    .nextBlock:
        movdqa  abcd_save, abcd
        movdqa  e0_save, e0

        %if XBITS == 32
        LOAD_MASK
        %endif

        LOAD_W 0
        LOAD_W 1
        LOAD_W 2
        LOAD_W 3

        paddd   e0, XMM_REG(w_regs)

        %assign k 0
        %rep NUM_ROUNDS4
          RND4 k
          %assign k k+1
        %endrep

        paddd   abcd, abcd_save

        add     rData, 64
        sub     rNum, 1
        jnz     .nextBlock

        REVERSE_STATE

        movdqu  [rState], abcd
        movd    dword [rState + 16], e0

    .end_c:
        MY_EPILOG




[section READONLY]

ALIGN 16
.Reverse_Endian_Mask db 15,14,13,12, 11,10,9,8, 7,6,5,4, 3,2,1,0

