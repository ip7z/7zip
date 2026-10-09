; LzmaDecOpt.asm -- ASM version of LzmaDec_DecodeReal_3() function
; 2024-06-18: Igor Pavlov : Public domain
;
; 3 - is the code compatibility version of LzmaDec_DecodeReal_*()
; function for check at link time.
; That code is tightly coupled with LzmaDec_TryDummy()
; and with another functions in LzmaDec.c file.
; CLzmaDec structure, (probs) array layout, input and output of
; LzmaDec_DecodeReal_*() must be equal in both versions (C / ASM).

%include "7zAsm.inc"

%if XBITS != 64
  %fatal <x64_IS_REQUIRED>
%endif

MY_ASM_START

; if Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT is     defined, we use additional SEGMENT with 64-byte alignment.
; if Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT is not defined, we use default SEGMENT (where default 16-byte alignment of segment is expected).
; The performance is almost identical in our tests.
; But the performance can depend from position of lzmadec code inside instruction cache
; or micro-op cache line (depending from low address bits in 32-byte/64-byte cache lines).
; And 64-byte alignment provides a more consistent speed regardless
; of the code's position in the executable.
; But also it's possible that code without Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT can be
; slightly faster than 64-bytes aligned code in some cases, if offset of lzmadec
; code in 64-byte block after compilation provides better speed by some reason.
; Note that Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT adds an extra section to the ELF file.
; If you don't want to get that extra section, do not define Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT.

%define Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT 1

%ifdef Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT
%macro MY_ALIGN 1
        ALIGN  %1
%endmacro
%else
%macro MY_ALIGN 1
        ; We expect that ".text" is aligned for 16-bytes.
        ; So we don't need large alignment inside out function.
        ALIGN  16
%endmacro
%endif


%macro MY_ALIGN_16 0
        MY_ALIGN 16
%endmacro

%macro MY_ALIGN_32 0
        MY_ALIGN 32
%endmacro

%macro MY_ALIGN_64 0
        MY_ALIGN 64
%endmacro


; %define _LZMA_SIZE_OPT 1

; %define _LZMA_PROB32 1

%ifdef _LZMA_PROB32
        %define PSHIFT 2
        %macro PLOAD 2 ; dest, mem
                mov     %1, dword [%2]
        %endmacro
        %macro PSTORE 2 ; src, mem
                mov     dword [%2], %1
        %endmacro
%else
        %define PSHIFT 1

        %macro PLOAD 2 ; dest, mem
                movzx   %1, word [%2]
        %endmacro

        %macro PSTORE 2 ; src, mem
            %assign n %find(%1, x0,x1,x2,x3,x4,x5,x6,x7)
            %if n == 0
                %fatal <PSTORE_src_param_IS_INCORRECT>
            %else
                ; x<n>  ==>  x<n>_W
                mov     word [%2], %tok(%strcat('x', %eval(n-1), "_W"))
            %endif
        %endmacro
%endif

%define PMULT       (1 << PSHIFT)
%define PMULT_HALF  (1 << (PSHIFT - 1))
%define PMULT_2     (1 << (PSHIFT + 1))

%define kMatchSpecLen_Error_Data (1 << 9)

;       x0      range
;       x1      pbPos / (prob) TREE
;       x2      probBranch / prm (MATCHED) / pbPos / cnt
;       x3      sym
;====== r4 ===  RSP
;       x5      cod
;       x6      t1 NORM_CALC / probs_state / dist
;       x7      t0 NORM_CALC / prob2 IF_BIT_1
;       x8      state
;       x9      match (MATCHED) / sym2 / dist2 / lpMask_reg
;       x10     kBitModelTotal_reg
;       r11     probs
;       x12     offs (MATCHED) / dic / len_temp
;       x13     processedPos
;       x14     bit (MATCHED) / dicPos
;       r15     buf


%define cod      x5
%define cod_L    x5_L
%define range    x0
%define state    x8
%define state_R  r8
%define buf      r15
%define processedPos  x13
%define kBitModelTotal_reg  x10

%define probBranch    x2
%define probBranch_R  r2
%define probBranch_W  x2_W

%define pbPos    x1
%define pbPos_R  r1

%define cnt      x2
%define cnt_R    r2

%define lpMask_reg  x9
%define dicPos   r14

%define sym      x3
%define sym_R    r3
%define sym_L    x3_L

%define probs    r11
%define dic      r12

%define t0       x7
%define t0_R     r7
%define t0_W     x7_W

%define prob2    t0
%define prob2_W  t0_W

%define t1       x6
%define t1_R     r6

%define probs_state      t1
%define probs_state_R    t1_R

%define prm      r2
%define match    x9
%define match_R  r9
%define offs     x12
%define offs_R   r12
%define bit      x14
%define bit_R    r14

%define sym2     x9
%define sym2_R   r9

%define len_temp  x12

%define dist     sym
%define dist2    x9



%define kNumBitModelTotalBits  11
%define kBitModelTotal         (1 << kNumBitModelTotalBits)
%define kNumMoveBits           5
%define kBitModelOffset        ((1 << kNumMoveBits) - 1)
%define kTopValue              (1 << 24)

%macro NORM_2 0
        ; movzx   t0, BYTE [buf]
        shl     cod, 8
        mov     cod_L, BYTE [buf]
        shl     range, 8
        ; or      cod, t0
        inc     buf
%endmacro


%macro NORM 0
        cmp     range, kTopValue
        jae     SHORT @F
        NORM_2
@@:
%endmacro


; ---------- Branch MACROS ----------

%macro UPDATE_0 3 ; probsArray, probOffset, probDisp
        mov     prob2, kBitModelTotal_reg
        sub     prob2, probBranch
        shr     prob2, kNumMoveBits
        add     probBranch, prob2
        PSTORE  probBranch, %2 * 1 + %1 + %3 * PMULT
%endmacro


%macro UPDATE_1 3 ; probsArray, probOffset, probDisp
        sub     prob2, range
        sub     cod, range
        mov     range, prob2
        mov     prob2, probBranch
        shr     probBranch, kNumMoveBits
        sub     prob2, probBranch
        PSTORE  prob2, %2 * 1 + %1 + %3 * PMULT
%endmacro


%macro CMP_COD 3 ; probsArray, probOffset, probDisp
        PLOAD   probBranch, %2 * 1 + %1 + %3 * PMULT
        NORM
        mov     prob2, range
        shr     range, kNumBitModelTotalBits
        imul    range, probBranch
        cmp     cod, range
%endmacro


%macro IF_BIT_1_NOUP 4 ; probsArray, probOffset, probDisp, toLabel
        CMP_COD %1, %2, %3
        jae     %4
%endmacro


%macro IF_BIT_1 4 ; probsArray, probOffset, probDisp, toLabel
        IF_BIT_1_NOUP %1, %2, %3, %4
        UPDATE_0 %1, %2, %3
%endmacro


%macro IF_BIT_0_NOUP 4 ; probsArray, probOffset, probDisp, toLabel
        CMP_COD %1, %2, %3
        jb      %4
%endmacro


; ---------- CMOV MACROS ----------

%macro NORM_CALC 1 ; prob
        NORM
        mov     t0, range
        shr     range, kNumBitModelTotalBits
        imul    range, %1
        sub     t0, range
        mov     t1, cod
        sub     cod, range
%endmacro


%macro PUP 2 ; prob, probPtr
        sub     t0, %1
        ; only sar works for both 16/32 bit prob modes
        sar     t0, kNumMoveBits
        add     t0, %1
        PSTORE  t0, %2
%endmacro


%macro PUP_SUB 3 ; prob, probPtr, symSub
        sbb     sym, %3
        PUP     %1, %2
%endmacro


%macro PUP_COD 3 ; prob, probPtr, symSub
        mov     t0, kBitModelOffset
        cmovb   cod, t1
        mov     t1, sym
        cmovb   t0, kBitModelTotal_reg
        PUP_SUB %1, %2, %3
%endmacro


%macro BIT_0 2 ; prob, probNext
        PLOAD   %1, probs + 1 * PMULT
        PLOAD   %2, probs + 1 * PMULT_2

        NORM_CALC %1
        
        cmovae  range, t0
        PLOAD   t0, probs + 1 * PMULT_2 + PMULT
        cmovae  %2, t0
        mov     t0, kBitModelOffset
        cmovb   cod, t1
        cmovb   t0, kBitModelTotal_reg
        mov     sym, 2
        PUP_SUB %1, probs + 1 * PMULT, 0 - 1
%endmacro


%macro BIT_1 2 ; prob, probNext
        PLOAD   %2, probs + sym_R * PMULT_2
        add     sym, sym
        
        NORM_CALC %1
        
        cmovae  range, t0
        PLOAD   t0, probs + sym_R * PMULT + PMULT
        cmovae  %2, t0
        PUP_COD %1, probs + t1_R * PMULT_HALF, 0 - 1
%endmacro


%macro BIT_2 2 ; prob, symSub
        add     sym, sym

        NORM_CALC %1
        
        cmovae  range, t0
        PUP_COD %1, probs + t1_R * PMULT_HALF, %2
%endmacro


; ---------- MATCHED LITERAL ----------

%macro LITM_0 0
        mov     offs, 256 * PMULT
        shl     match, (PSHIFT + 1)
        mov     bit, offs
        and     bit, match
        PLOAD   x1, probs + 256 * PMULT + bit_R * 1 + 1 * PMULT
        lea     prm, [probs + 256 * PMULT + bit_R * 1 + 1 * PMULT]
        ; lea     prm, [probs + 256 * PMULT + 1 * PMULT]
        ; add     prm, bit_R
        xor     offs, bit
        add     match, match

        NORM_CALC x1

        cmovae  offs, bit
        mov     bit, match
        cmovae  range, t0
        mov     t0, kBitModelOffset
        cmovb   cod, t1
        cmovb   t0, kBitModelTotal_reg
        mov     sym, 0
        PUP_SUB x1, prm, -2-1
%endmacro


%macro LITM 0
        and     bit, offs
        lea     prm, [probs + offs_R * 1]
        add     prm, bit_R
        PLOAD   x1, prm + sym_R * PMULT
        xor     offs, bit
        add     sym, sym
        add     match, match

        NORM_CALC x1

        cmovae  offs, bit
        mov     bit, match
        cmovae  range, t0
        PUP_COD x1, prm + t1_R * PMULT_HALF, - 1
%endmacro


%macro LITM_2 0
        and     bit, offs
        lea     prm, [probs + offs_R * 1]
        add     prm, bit_R
        PLOAD   x1, prm + sym_R * PMULT
        add     sym, sym

        NORM_CALC x1

        cmovae  range, t0
        PUP_COD x1, prm + t1_R * PMULT_HALF, 256 - 1
%endmacro


; ---------- REVERSE BITS ----------

%macro REV_0 2 ; prob, probNext
        ; PLOAD   %1, probs + 1 * PMULT
        ; lea     sym2_R, [probs + 2 * PMULT]
        ; PLOAD   %2, probs + 2 * PMULT
        PLOAD   %2, sym2_R

        NORM_CALC %1

        cmovae  range, t0
        PLOAD   t0, probs + 3 * PMULT
        cmovae  %2, t0
        cmovb   cod, t1
        mov     t0, kBitModelOffset
        cmovb   t0, kBitModelTotal_reg
        lea     t1_R, [probs + 3 * PMULT]
        cmovae  sym2_R, t1_R
        PUP     %1, probs + 1 * PMULT
%endmacro


%macro REV_1 3 ; prob, probNext, step
        add     sym2_R, %3 * PMULT
        PLOAD   %2, sym2_R

        NORM_CALC %1

        cmovae  range, t0
        PLOAD   t0, sym2_R + %3 * PMULT
        cmovae  %2, t0
        cmovb   cod, t1
        mov     t0, kBitModelOffset
        cmovb   t0, kBitModelTotal_reg
        lea     t1_R, [sym2_R + %3 * PMULT]
        cmovae  sym2_R, t1_R
        PUP     %1, t1_R - %3 * PMULT_2
%endmacro


%macro REV_2 2 ; prob, step
        sub     sym2_R, probs
        shr     sym2, PSHIFT
        or      sym, sym2

        NORM_CALC %1

        cmovae  range, t0
        ;lea     t0, [sym - %2]
        lea     t0, [sym_R - %2]
        cmovb   sym, t0
        cmovb   cod, t1
        mov     t0, kBitModelOffset
        cmovb   t0, kBitModelTotal_reg
        PUP     %1, probs + sym2_R * PMULT
%endmacro


%macro REV_1_VAR 1 ; prob
        PLOAD   %1, sym_R
        mov     probs, sym_R
        add     sym_R, sym2_R

        NORM_CALC %1

        cmovae  range, t0
        lea     t0_R, [sym_R + 1 * sym2_R]
        cmovae  sym_R, t0_R
        mov     t0, kBitModelOffset
        cmovb   cod, t1
        ; mov     t1, kBitModelTotal
        ; cmovb   t0, t1
        cmovb   t0, kBitModelTotal_reg
        add     sym2, sym2
        PUP     %1, probs
%endmacro




%macro LIT_PROBS 1 ; lpMaskParam
        ; prob += (UInt32)3 * ((((processedPos << 8) + dic[(dicPos == 0 ? dicBufSize : dicPos) - 1]) & lpMask) << lc);
        mov     t0, processedPos
        shl     t0, 8
        add     sym, t0
        and     sym, %1
        add     probs_state_R, pbPos_R
        mov     x1, LOC(lc2)
        lea     sym, dword [sym_R + 2 * sym_R]
        add     probs, Literal * PMULT
        shl     sym, x1_L
        add     probs, sym_R
        UPDATE_0 probs_state_R, 0, IsMatch
        inc     processedPos
%endmacro



%define kNumPosBitsMax         4
%define kNumPosStatesMax       (1 << kNumPosBitsMax)

%define kLenNumLowBits         3
%define kLenNumLowSymbols      (1 << kLenNumLowBits)
%define kLenNumHighBits        8
%define kLenNumHighSymbols     (1 << kLenNumHighBits)
%define kNumLenProbs           (2 * kLenNumLowSymbols * kNumPosStatesMax + kLenNumHighSymbols)

%define LenLow                 0
%define LenChoice              LenLow
%define LenChoice2             (LenLow + kLenNumLowSymbols)
%define LenHigh                (LenLow + 2 * kLenNumLowSymbols * kNumPosStatesMax)

%define kNumStates             12
%define kNumStates2            16
%define kNumLitStates          7

%define kStartPosModelIndex    4
%define kEndPosModelIndex      14
%define kNumFullDistances      (1 << (kEndPosModelIndex >> 1))

%define kNumPosSlotBits        6
%define kNumLenToPosStates     4

%define kNumAlignBits          4
%define kAlignTableSize        (1 << kNumAlignBits)

%define kMatchMinLen           2
%define kMatchSpecLenStart     (kMatchMinLen + kLenNumLowSymbols * 2 + kLenNumHighSymbols)

%define kStartOffset   1664
%define SpecPos        (-kStartOffset)
%define IsRep0Long     (SpecPos + kNumFullDistances)
%define RepLenCoder    (IsRep0Long + (kNumStates2 << kNumPosBitsMax))
%define LenCoder       (RepLenCoder + kNumLenProbs)
%define IsMatch        (LenCoder + kNumLenProbs)
%define kAlign         (IsMatch + (kNumStates2 << kNumPosBitsMax))
%define IsRep          (kAlign + kAlignTableSize)
%define IsRepG0        (IsRep + kNumStates)
%define IsRepG1        (IsRepG0 + kNumStates)
%define IsRepG2        (IsRepG1 + kNumStates)
%define PosSlot        (IsRepG2 + kNumStates)
%define Literal        (PosSlot + (kNumLenToPosStates << kNumPosSlotBits))
%define NUM_BASE_PROBS (Literal + kStartOffset)

%if kAlign != 0
  %fatal <Stop_Compiling_Bad_LZMA_kAlign>
%endif

%if NUM_BASE_PROBS != 1984
  %fatal <Stop_Compiling_Bad_LZMA_PROBS>
%endif


%define PTR_FIELD  dq ?

struc CLzmaDec_Asm
        .lc                 db ?
        .lp                 db ?
        .pb                 db ?
        ._pad_              db ?
        .dicSize            dd ?

        .probs_Spec         PTR_FIELD
        .probs_1664         PTR_FIELD
        .dic_Spec           PTR_FIELD
        .dicBufSize         PTR_FIELD
        .dicPos_Spec        PTR_FIELD
        .buf_Spec           PTR_FIELD

        .range_Spec         dd ?
        .code_Spec          dd ?
        .processedPos_Spec  dd ?
        .checkDicSize       dd ?
        .rep0               dd ?
        .rep1               dd ?
        .rep2               dd ?
        .rep3               dd ?
        .state_Spec         dd ?
        .remainLen          dd ?
endstruc


struc CLzmaDec_Asm_Loc
        .Old_RSP       PTR_FIELD
        .lzmaPtr       PTR_FIELD
        ._pad0_        PTR_FIELD
        ._pad1_        PTR_FIELD
        ._pad2_        PTR_FIELD
        .dicBufSize    PTR_FIELD
        .probs_Spec    PTR_FIELD
        .dic_Spec      PTR_FIELD
        
        .limit         PTR_FIELD
        .bufLimit      PTR_FIELD
        .lc2           dd ?
        .lpMask        dd ?
        .pbMask        dd ?
        .checkDicSize  dd ?

        ._pad_         dd ?
        .remainLen     dd ?
        .dicPos_Spec   PTR_FIELD
        .rep0          dd ?
        .rep1          dd ?
        .rep2          dd ?
        .rep3          dd ?
endstruc


%define GLOB_2(x)  [sym_R + CLzmaDec_Asm.     %+ x]
%define GLOB(x)    [r1    + CLzmaDec_Asm.     %+ x]
%define LOC_0(x)   [r0    + CLzmaDec_Asm_Loc. %+ x]
%define LOC(x)     [RSP   + CLzmaDec_Asm_Loc. %+ x]


%macro COPY_VAR 1
        mov     t0, GLOB_2(%1)
        mov     LOC_0(%1), t0
%endmacro


%macro RESTORE_VAR 1
        mov     t0, LOC(%1)
        mov     GLOB(%1), t0
%endmacro


%macro IsMatchBranch_Pre 0
        ; prob = probs + IsMatch + (state << kNumPosBitsMax) + posState;
        mov     pbPos, LOC(pbMask)
        and     pbPos, processedPos
        shl     pbPos, (kLenNumLowBits + 1 + PSHIFT)
        lea     probs_state_R, [probs + 1 * state_R]
%endmacro


%macro IsMatchBranch 0
        IsMatchBranch_Pre
        IF_BIT_1 probs_state_R, pbPos_R, IsMatch, .IsMatch_label
%endmacro
        

%macro CheckLimits 0
        cmp     buf, LOC(bufLimit)
        jae     .fin_OK
        cmp     dicPos, LOC(limit)
        jae     .fin_OK
%endmacro



; RSP is (16x + 8) bytes aligned in WIN64-x64
; %define LocalSize ((((SIZEOF CLzmaDec_Asm_Loc) + 7) / 16 * 16) + 8)

%define PARAM_lzma       REG_ABI_PARAM_0
%define PARAM_limit      REG_ABI_PARAM_1
%define PARAM_bufLimit   REG_ABI_PARAM_2

%ifdef Z7_LZMA_DEC_OPT_ASM_USE_SEGMENT
  ; MY_ALIGN_64
  [section .text$LZMADECOPT align=64 exec]
%else
  MY_ALIGN_16
%endif
MY_PROC LzmaDec_DecodeReal_3, 3
        MY_PUSH_PRESERVED_ABI_REGS

        lea     r0, [RSP - CLzmaDec_Asm_Loc_size]
        and     r0, -128
        mov     r5, RSP
        mov     RSP, r0
        mov     LOC_0(Old_RSP), r5
        mov     LOC_0(lzmaPtr), PARAM_lzma

        mov     LOC_0(remainLen), dword 0  ; remainLen must be ZERO

        mov     LOC_0(bufLimit), PARAM_bufLimit
        mov     sym_R, PARAM_lzma  ;  CLzmaDec_Asm_Loc pointer for GLOB_2
        mov     dic, GLOB_2(dic_Spec)
        add     PARAM_limit, dic
        mov     LOC_0(limit), PARAM_limit

        COPY_VAR  rep0
        COPY_VAR  rep1
        COPY_VAR  rep2
        COPY_VAR  rep3

        mov     dicPos, GLOB_2(dicPos_Spec)
        add     dicPos, dic
        mov     LOC_0(dicPos_Spec), dicPos
        mov     LOC_0(dic_Spec), dic

        mov     x1_L, GLOB_2(pb)
        mov     t0, 1
        shl     t0, x1_L
        dec     t0
        mov     LOC_0(pbMask), t0

        ; unsigned pbMask = ((unsigned)1 << (p->prop.pb)) - 1;
        ; unsigned lc = p->prop.lc;
        ; unsigned lpMask = ((unsigned)0x100 << p->prop.lp) - ((unsigned)0x100 >> lc);

        mov     x1_L, GLOB_2(lc)
        mov     x2, 100h
        mov     t0, x2
        shr     x2, x1_L
        ; inc     x1
        add     x1_L, PSHIFT
        mov     LOC_0(lc2), x1
        mov     x1_L, GLOB_2(lp)
        shl     t0, x1_L
        sub     t0, x2
        mov     LOC_0(lpMask), t0
        mov     lpMask_reg, t0
        
        ; mov     probs, GLOB_2(probs_Spec)
        ; add     probs, kStartOffset << PSHIFT
        mov     probs, GLOB_2(probs_1664)
        mov     LOC_0(probs_Spec), probs

        mov     t0_R, GLOB_2(dicBufSize)
        mov     LOC_0(dicBufSize), t0_R
       
        mov     x1, GLOB_2(checkDicSize)
        mov     LOC_0(checkDicSize), x1

        mov     processedPos, GLOB_2(processedPos_Spec)

        mov     state, GLOB_2(state_Spec)
        shl     state, PSHIFT

        mov     buf,   GLOB_2(buf_Spec)
        mov     range, GLOB_2(range_Spec)
        mov     cod,   GLOB_2(code_Spec)
        mov     kBitModelTotal_reg, kBitModelTotal
        xor     sym, sym

        ; if (processedPos != 0 || checkDicSize != 0)
        or      x1, processedPos
        jz      @F
        
        add     t0_R, dic
        cmp     dicPos, dic
        cmovnz  t0_R, dicPos
        movzx   sym, byte [t0_R - 1]

@@:
        IsMatchBranch_Pre
        cmp     state, 4 * PMULT
        jb      .lit_end
        cmp     state, kNumLitStates * PMULT
        jb      .lit_matched_end
        jmp     .lz_end
        

        

; ---------- LITERAL ----------
MY_ALIGN_64
.lit_start:
        xor     state, state
.lit_start_2:
        LIT_PROBS lpMask_reg

    %ifdef _LZMA_SIZE_OPT

        PLOAD   x1, probs + 1 * PMULT
        mov     sym, 1
MY_ALIGN_16
.lit_loop:
        BIT_1   x1, x2
        mov     x1, x2
        cmp     sym, 127
        jbe     .lit_loop
        
    %else
        
        BIT_0   x1, x2
      %rep 3
        BIT_1   x2, x1
        BIT_1   x1, x2
      %endrep
        
    %endif

        BIT_2   x2, 256 - 1
        
        ; mov     dic, LOC(dic_Spec)
        mov     probs, LOC(probs_Spec)
        IsMatchBranch_Pre
        mov     byte [dicPos], sym_L
        inc     dicPos
                
        CheckLimits
.lit_end:
        IF_BIT_0_NOUP probs_state_R, pbPos_R, IsMatch, .lit_start

        ; jmp     .IsMatch_label
        
; ---------- MATCHES ----------
; MY_ALIGN_32
.IsMatch_label:
        UPDATE_1 probs_state_R, pbPos_R, IsMatch
        IF_BIT_1 probs_state_R, 0, IsRep, .IsRep_label

        add     probs, LenCoder * PMULT
        add     state, kNumStates * PMULT

; ---------- LEN DECODE ----------
.len_decode:
        mov     len_temp, 8 - 1 - kMatchMinLen
        IF_BIT_0_NOUP probs, 0, 0, .len_mid_0
        UPDATE_1 probs, 0, 0
        add     probs, (1 << (kLenNumLowBits + PSHIFT))
        mov     len_temp, -1 - kMatchMinLen
        IF_BIT_0_NOUP probs, 0, 0, .len_mid_0
        UPDATE_1 probs, 0, 0
        add     probs, LenHigh * PMULT - (1 << (kLenNumLowBits + PSHIFT))
        mov     sym, 1
        PLOAD   x1, probs + 1 * PMULT

MY_ALIGN_32
.len8_loop:
        BIT_1   x1, x2
        mov     x1, x2
        cmp     sym, 64
        jb      .len8_loop

        mov     len_temp, (kLenNumHighSymbols - kLenNumLowSymbols * 2) - 1 - kMatchMinLen
        ;jmp     short .len_mid_2 ; we use short here for MASM that doesn't optimize that code as another assembler programs
        jmp     .len_mid_2

MY_ALIGN_32
.len_mid_0:
        UPDATE_0 probs, 0, 0
        add     probs, pbPos_R
        BIT_0   x2, x1
.len_mid_2:
        BIT_1   x1, x2
        BIT_2   x2, len_temp
        mov     probs, LOC(probs_Spec)
        cmp     state, kNumStates * PMULT
        jb      .copy_match


; ---------- DECODE DISTANCE ----------
        ; probs + PosSlot + ((len < kNumLenToPosStates ? len : kNumLenToPosStates - 1) << kNumPosSlotBits);

        mov     t0,  3 + kMatchMinLen
        cmp     sym, 3 + kMatchMinLen
        cmovb   t0, sym
        add     probs, PosSlot * PMULT - (kMatchMinLen << (kNumPosSlotBits + PSHIFT))
        shl     t0, (kNumPosSlotBits + PSHIFT)
        add     probs, t0_R

        ; sym = Len
        ; mov     LOC(remainLen), sym
        mov     len_temp, sym

    %ifdef _LZMA_SIZE_OPT

        PLOAD   x1, probs + 1 * PMULT
        mov     sym, 1
MY_ALIGN_16
.slot_loop:
        BIT_1   x1, x2
        mov     x1, x2
        cmp     sym, 32
        jb      .slot_loop

    %else

        BIT_0   x1, x2
      %rep 2
        BIT_1   x2, x1
        BIT_1   x1, x2
      %endrep

    %endif

        mov     x1, sym
        BIT_2   x2, 64-1

        and     sym, 3
        mov     probs, LOC(probs_Spec)
        cmp     x1, 32 + kEndPosModelIndex / 2
        jb      .short_dist

        ;  unsigned numDirectBits = (unsigned)(((distance >> 1) - 1));
        sub     x1, (32 + 1 + kNumAlignBits)
        ;  distance = (2 | (distance & 1));
        or      sym, 2
        PLOAD   x2, probs + 1 * PMULT
        shl     sym, kNumAlignBits + 1
        lea     sym2_R, [probs + 2 * PMULT]

        jmp     .direct_norm
        ; lea     t1, [sym_R + (1 << kNumAlignBits)]
        ; cmp     range, kTopValue
        ; jb      .direct_norm

; ---------- DIRECT DISTANCE ----------
MY_ALIGN_32
.direct_loop:
        shr     range, 1
        mov     t0, cod
        sub     cod, range
        cmovs   cod, t0
        cmovns  sym, t1

        ;sub     cod, range
        ;mov     x2, cod
        ;sar     x2, 31
        ;lea     sym, dword [r2 + sym_R * 2 + 1]
        ;and     x2, range
        ;add     cod, x2

        dec     x1
        je      .direct_end

        add     sym, sym
.direct_norm:
        lea     t1, [sym_R + (1 << kNumAlignBits)]
        cmp     range, kTopValue
        jae     near .direct_loop
        ; we align for 32 here with "near ptr" command above
        NORM_2
        jmp     .direct_loop

MY_ALIGN_32
.direct_end:
        ;  prob =  + kAlign;
        ;  distance <<= kNumAlignBits;
        REV_0   x2, x1
        REV_1   x1, x2, 2
        REV_1   x2, x1, 4
        REV_2   x1, 8

.decode_dist_end:

        ; if (distance >= (checkDicSize == 0 ? processedPos: checkDicSize))

        mov     t1, LOC(rep0)
        mov     x1, LOC(rep1)
        mov     x2, LOC(rep2)

        mov     t0, LOC(checkDicSize)
        test    t0, t0
        cmove   t0, processedPos
        cmp     sym, t0
        jae     .end_of_payload
        ; jmp     .end_of_payload ; for debug

        ; rep3 = rep2;
        ; rep2 = rep1;
        ; rep1 = rep0;
        ; rep0 = distance + 1;

        inc     sym
        mov     LOC(rep0), sym
        ; mov     sym, LOC(remainLen)
        mov     sym, len_temp
        mov     LOC(rep1), t1
        mov     LOC(rep2), x1
        mov     LOC(rep3), x2

        ; state = (state < kNumStates + kNumLitStates) ? kNumLitStates : kNumLitStates + 3;
        cmp     state, (kNumStates + kNumLitStates) * PMULT
        mov     state, kNumLitStates * PMULT
        mov     t0, (kNumLitStates + 3) * PMULT
        cmovae  state, t0

        
; ---------- COPY MATCH ----------
.copy_match:

        ; len += kMatchMinLen;
        ; add     sym, kMatchMinLen

        ; if ((rem = limit - dicPos) == 0)
        ; {
        ;   p->dicPos = dicPos;
        ;   return SZ_ERROR_DATA;
        ; }
        mov     cnt_R, LOC(limit)
        sub     cnt_R, dicPos
        jz      .fin_dicPos_LIMIT

        ; curLen = ((rem < len) ? (unsigned)rem : len);
        cmp     cnt_R, sym_R
        ; cmovae  cnt_R, sym_R ; 64-bit
        cmovae  cnt, sym ; 32-bit

        mov     dic, LOC(dic_Spec)
        mov     x1, LOC(rep0)

        mov     t0_R, dicPos
        add     dicPos, cnt_R
        ; processedPos += curLen;
        add     processedPos, cnt
        ; len -= curLen;
        sub     sym, cnt
        mov     LOC(remainLen), sym

        sub     t0_R, dic

        ; pos = dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0);
        sub     t0_R, r1
        jae     @F

        mov     r1, LOC(dicBufSize)
        add     t0_R, r1
        sub     r1, t0_R
        cmp     cnt_R, r1
        ja      .copy_match_cross
@@:
        ; if (curLen <= dicBufSize - pos)

; ---------- COPY MATCH FAST ----------
        ; Byte *dest = dic + dicPos;
        ; mov     r1, dic
        ; ptrdiff_t src = (ptrdiff_t)pos - (ptrdiff_t)dicPos;
        ; sub   t0_R, dicPos
        ; dicPos += curLen;

        ; const Byte *lim = dest + curLen;
        add     t0_R, dic
        movzx   sym, byte [t0_R]
        add     t0_R, cnt_R
        neg     cnt_R
        ; lea     r1, [dicPos - 1]
.copy_common:
        dec     dicPos
        ; cmp   LOC(rep0), 1
        ; je    rep0Label

        ; t0_R - src_lim
        ; r1 - dest_lim - 1
        ; cnt_R - (-cnt)

        IsMatchBranch_Pre
        inc     cnt_R
        jz      .copy_end
MY_ALIGN_16
@@:
        mov     byte [cnt_R * 1 + dicPos], sym_L
        movzx   sym, byte [cnt_R * 1 + t0_R]
        inc     cnt_R
        jnz     @B

.copy_end:
.lz_end_match:
        mov     byte [dicPos], sym_L
        inc     dicPos

        ; IsMatchBranch_Pre
        CheckLimits
.lz_end:
        IF_BIT_1_NOUP probs_state_R, pbPos_R, IsMatch, .IsMatch_label



; ---------- LITERAL MATCHED ----------

        LIT_PROBS LOC(lpMask)

        ; matchByte = dic[dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0)];
        mov     x1, LOC(rep0)
        ; mov     dic, LOC(dic_Spec)
        mov     LOC(dicPos_Spec), dicPos

        ; state -= (state < 10) ? 3 : 6;
        lea     t0, [state_R - 6 * PMULT]
        sub     state, 3 * PMULT
        cmp     state, 7 * PMULT
        cmovae  state, t0

        sub     dicPos, dic
        sub     dicPos, r1
        jae     @F
        add     dicPos, LOC(dicBufSize)
@@:
        ;xor     t0, t0
        ;sub     dicPos, r1
        ;cmovb   t0_R, LOC(dicBufSize)
        
        movzx   match, byte [dic + dicPos * 1]

    %ifdef _LZMA_SIZE_OPT

        mov     offs, 256 * PMULT
        shl     match, (PSHIFT + 1)
        mov     bit, match
        mov     sym, 1
MY_ALIGN_16
.litm_loop:
        LITM
        cmp     sym, 256
        jb      .litm_loop
        sub     sym, 256

    %else

        LITM_0
      %rep 6
        LITM
      %endrep
        LITM_2

    %endif

        mov     probs, LOC(probs_Spec)
        IsMatchBranch_Pre
        ; mov     dic, LOC(dic_Spec)
        mov     dicPos, LOC(dicPos_Spec)
        mov     byte [dicPos], sym_L
        inc     dicPos

        CheckLimits
.lit_matched_end:
        IF_BIT_1_NOUP probs_state_R, pbPos_R, IsMatch, .IsMatch_label
        ; IsMatchBranch
        mov     lpMask_reg, LOC(lpMask)
        sub     state, 3 * PMULT
        jmp     .lit_start_2



; ---------- REP 0 LITERAL ----------
MY_ALIGN_32
.IsRep0Short_label:
        UPDATE_0 probs_state_R, pbPos_R, IsRep0Long

        ; dic[dicPos] = dic[dicPos - rep0 + (dicPos < rep0 ? dicBufSize : 0)];
        mov     dic, LOC(dic_Spec)
        mov     t0_R, dicPos
        mov     probBranch, LOC(rep0)
        sub     t0_R, dic

        sub     probs, RepLenCoder * PMULT

        ; state = state < kNumLitStates ? 9 : 11;
        or      state, 1 * PMULT

        ; the caller doesn't allow (dicPos >= limit) case for REP_SHORT
        ; so we don't need the following (dicPos == limit) check here:
        ; cmp     dicPos, LOC(limit)
        ; jae     fin_dicPos_LIMIT_REP_SHORT

        inc     processedPos

        IsMatchBranch_Pre

        ;xor     sym, sym
        ;sub     t0_R, probBranch_R
        ;cmovb   sym_R, LOC(dicBufSize)
        ;add     t0_R, sym_R
        sub     t0_R, probBranch_R
        jae     @F
        add     t0_R, LOC(dicBufSize)
@@:
        movzx   sym, byte [dic + t0_R * 1]
        jmp     .lz_end_match


MY_ALIGN_32
.IsRep_label:
        UPDATE_1 probs_state_R, 0, IsRep

        ; The (checkDicSize == 0 && processedPos == 0) case was checked before in LzmaDec.c with kBadRepCode.
        ; So we don't check it here.

        ; mov     t0, processedPos
        ; or      t0, LOC(checkDicSize)
        ; jz      fin_ERROR_2

        ; state = state < kNumLitStates ? 8 : 11;
        cmp     state, kNumLitStates * PMULT
        mov     state, 8 * PMULT
        mov     probBranch, 11 * PMULT
        cmovae  state, probBranch

        ; prob = probs + RepLenCoder;
        add     probs, RepLenCoder * PMULT

        IF_BIT_1 probs_state_R, 0, IsRepG0, .IsRepG0_label
        IF_BIT_0_NOUP probs_state_R, pbPos_R, IsRep0Long, .IsRep0Short_label
        UPDATE_1 probs_state_R, pbPos_R, IsRep0Long
        jmp     .len_decode

MY_ALIGN_32
.IsRepG0_label:
        UPDATE_1 probs_state_R, 0, IsRepG0
        mov     dist2, LOC(rep0)
        mov     dist, LOC(rep1)
        mov     LOC(rep1), dist2

        IF_BIT_1 probs_state_R, 0, IsRepG1, .IsRepG1_label
        mov     LOC(rep0), dist
        jmp     .len_decode

; MY_ALIGN_32
.IsRepG1_label:
        UPDATE_1 probs_state_R, 0, IsRepG1
        mov     dist2, LOC(rep2)
        mov     LOC(rep2), dist

        IF_BIT_1 probs_state_R, 0, IsRepG2, .IsRepG2_label
        mov     LOC(rep0), dist2
        jmp     .len_decode

; MY_ALIGN_32
.IsRepG2_label:
        UPDATE_1 probs_state_R, 0, IsRepG2
        mov     dist, LOC(rep3)
        mov     LOC(rep3), dist2
        mov     LOC(rep0), dist
        jmp     .len_decode



; ---------- SPEC SHORT DISTANCE ----------

MY_ALIGN_32
.short_dist:
        sub     x1, 32 + 1
        jbe     .decode_dist_end
        or      sym, 2
        shl     sym, x1_L
        lea     sym_R, [probs + sym_R * PMULT + SpecPos * PMULT + 1 * PMULT]
        mov     sym2, PMULT ; step
MY_ALIGN_32
.spec_loop:
        REV_1_VAR x2
        dec     x1
        jnz     .spec_loop

        mov     probs, LOC(probs_Spec)
        sub     sym, sym2
        sub     sym, SpecPos * PMULT
        sub     sym_R, probs
        shr     sym, PSHIFT

        jmp     .decode_dist_end


; ---------- COPY MATCH CROSS ----------
.copy_match_cross:
        ; t0_R - src pos
        ; r1 - len to dicBufSize
        ; cnt_R - total copy len

        mov     t1_R, t0_R         ; srcPos
        mov     t0_R, dic
        mov     r1, LOC(dicBufSize)
        neg     cnt_R
@@:
        movzx   sym, byte [t1_R * 1 + t0_R]
        inc     t1_R
        mov     byte [cnt_R * 1 + dicPos], sym_L
        inc     cnt_R
        cmp     t1_R, r1
        jne     @B

        movzx   sym, byte [t0_R]
        sub     t0_R, cnt_R
        jmp     .copy_common




; fin_dicPos_LIMIT_REP_SHORT:
        ; mov     sym, 1

.fin_dicPos_LIMIT:
        mov     LOC(remainLen), sym
        jmp     .fin_OK
        ; For more strict mode we can stop decoding with error
        ; mov     sym, 1
        ; jmp     .fin


.fin_ERROR_MATCH_DIST:

        ; rep3 = rep2;
        ; rep2 = rep1;
        ; rep1 = rep0;
        ; rep0 = distance + 1;

        add     len_temp, kMatchSpecLen_Error_Data
        mov     LOC(remainLen), len_temp

        mov     LOC(rep0), sym
        mov     LOC(rep1), t1
        mov     LOC(rep2), x1
        mov     LOC(rep3), x2

        ; state = (state < kNumStates + kNumLitStates) ? kNumLitStates : kNumLitStates + 3;
        cmp     state, (kNumStates + kNumLitStates) * PMULT
        mov     state, kNumLitStates * PMULT
        mov     t0, (kNumLitStates + 3) * PMULT
        cmovae  state, t0

        ; jmp     .fin_OK
        mov     sym, 1
        jmp     .fin

.end_of_payload:
        inc     sym
        jnz     .fin_ERROR_MATCH_DIST

        mov     LOC(remainLen), dword kMatchSpecLenStart
        sub     state, kNumStates * PMULT

.fin_OK:
        xor     sym, sym

.fin:
        NORM

        mov     r1, LOC(lzmaPtr)

        sub     dicPos, LOC(dic_Spec)
        mov     GLOB(dicPos_Spec), dicPos
        mov     GLOB(buf_Spec), buf
        mov     GLOB(range_Spec), range
        mov     GLOB(code_Spec), cod
        shr     state, PSHIFT
        mov     GLOB(state_Spec), state
        mov     GLOB(processedPos_Spec), processedPos

        RESTORE_VAR  remainLen
        RESTORE_VAR  rep0
        RESTORE_VAR  rep1
        RESTORE_VAR  rep2
        RESTORE_VAR  rep3

        mov     x0, sym

        mov     RSP, LOC(Old_RSP)

        MY_POP_PRESERVED_ABI_REGS
        MY_ENDP

