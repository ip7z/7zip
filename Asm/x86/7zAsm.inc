; 7zAsm.asm -- ASM macros
; 2023-12-08 : Igor Pavlov : Public domain
; 2026-07-29 : Carsten Janssen : x86 ASM files were translated from MASM into NASM dialect


%define XBITS __?BITS?__

%define WINDOWS 1
%define LINUX   2

%ifidni   __?OUTPUT_FORMAT?__, win32
  %define ABI WINDOWS
%elifidni __?OUTPUT_FORMAT?__, win64
  %define ABI WINDOWS
%else
  %define ABI LINUX
%endif

; Use ABI_CDECL for x86 (32-bit) only
; if ABI_CDECL is not defined, we use fastcall ABI
%if (XBITS == 32) && (ABI == WINDOWS)
  %ifdef ABI_CDECL
    %define IS_CDECL 1
  %endif
%endif
%ifndef IS_CDECL
    %define IS_CDECL 0
%endif
%if IS_CDECL == 1
  %pragma win gprefix _
%endif

%macro MY_ASM_START 0
  default rel
  %use smartalign
  %if XBITS == 32
    [section .text$00 align=16 exec]
  %else
    [section .text]
  %endif
%endmacro

%if ABI == LINUX
  %define READONLY .rodata
%else
  %define READONLY .rdata
%endif

%macro GLOBAL_FUNC 1
  %if ABI == LINUX
    global %1: function
  %else
    global %1
  %endif
  %1:
%endmacro

%macro MY_PROC 2
  ALIGN 16
  %assign proc_numParams %2
  %if (XBITS == 64) || (ABI == LINUX) || (IS_CDECL == 1)
    GLOBAL_FUNC %1
  %else
    GLOBAL_FUNC %tok(%strcat(@, %1, @, %eval(%2 * 4)))
  %endif
%endmacro

%macro MY_ENDP 0
  %if (XBITS == 64) || (IS_CDECL == 1) || (proc_numParams < 3)
    ret
  %else
    ret (proc_numParams - 2) * 4
  %endif
%endmacro


%if XBITS == 64
  %define REG_SIZE       8
  %define REG_LOGAR_SIZE 3
%else
  %define REG_SIZE       4
  %define REG_LOGAR_SIZE 2
%endif

  %define x0 EAX
  %define x1 ECX
  %define x2 EDX
  %define x3 EBX
  %define x4 ESP
  %define x5 EBP
  %define x6 ESI
  %define x7 EDI

  %define x0_W AX
  %define x1_W CX
  %define x2_W DX
  %define x3_W BX

  %define x5_W BP
  %define x6_W SI
  %define x7_W DI

  %define x0_L AL
  %define x1_L CL
  %define x2_L DL
  %define x3_L BL

  %define x0_H AH
  %define x1_H CH
  %define x2_H DH
  %define x3_H BH

;  %define r0_L AL
;  %define r1_L CL
;  %define r2_L DL
;  %define r3_L BL

;  %define r0_H AH
;  %define r1_H CH
;  %define r2_H DH
;  %define r3_H BH


%if XBITS == 64
  %define x5_L  BPL
  %define x6_L  SIL
  %define x7_L  DIL
  %define x8_L  r8b
  %define x9_L  r9b
  %define x10_L r10b
  %define x11_L r11b
  %define x12_L r12b
  %define x13_L r13b
  %define x14_L r14b
  %define x15_L r15b

  %define r0  RAX
  %define r1  RCX
  %define r2  RDX
  %define r3  RBX
  %define r4  RSP
  %define r5  RBP
  %define r6  RSI
  %define r7  RDI
  %define x8  r8d
  %define x9  r9d
  %define x10 r10d
  %define x11 r11d
  %define x12 r12d
  %define x13 r13d
  %define x14 r14d
  %define x15 r15d
%else
  %define r0 x0
  %define r1 x1
  %define r2 x2
  %define r3 x3
  %define r4 x4
  %define r5 x5
  %define r6 x6
  %define r7 x7
%endif

  %define x0_R  r0
  %define x1_R  r1
  %define x2_R  r2
  %define x3_R  r3
  %define x4_R  r4
  %define x5_R  r5
  %define x6_R  r6
  %define x7_R  r7
  %define x8_R  r8
  %define x9_R  r9
  %define x10_R r10
  %define x11_R r11
  %define x12_R r12
  %define x13_R r13
  %define x14_R r14
  %define x15_R r15

%if (XBITS == 64) && (ABI == LINUX)
  %macro MY_PUSH_2_REGS 0
      push    r3
      push    r5
  %endmacro

  %macro MY_POP_2_REGS 0
      pop     r5
      pop     r3
  %endmacro
%endif


%macro MY_PUSH_4_REGS 0
    push    r3
    push    r5
    push    r6
    push    r7
%endmacro

%macro MY_POP_4_REGS 0
    pop     r7
    pop     r6
    pop     r5
    pop     r3
%endmacro


; for fastcall and for WIN-x64
%define REG_PARAM_0_x   x1
%define REG_PARAM_0     r1
%define REG_PARAM_1_x   x2
%define REG_PARAM_1     r2

%if XBITS == 32
; for x86-fastcall

%define REG_ABI_PARAM_0_x REG_PARAM_0_x
%define REG_ABI_PARAM_0   REG_PARAM_0
%define REG_ABI_PARAM_1_x REG_PARAM_1_x
%define REG_ABI_PARAM_1   REG_PARAM_1

%macro MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11 0
        MY_PUSH_4_REGS
%endmacro

%macro MY_POP_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11 0
        MY_POP_4_REGS
%endmacro

%else
; x64

%if ABI == WINDOWS

; for WIN-x64:
%define REG_PARAM_2_x   x8
%define REG_PARAM_2     r8
%define REG_PARAM_3     r9

%define REG_ABI_PARAM_0_x REG_PARAM_0_x
%define REG_ABI_PARAM_0   REG_PARAM_0
%define REG_ABI_PARAM_1_x REG_PARAM_1_x
%define REG_ABI_PARAM_1   REG_PARAM_1
%define REG_ABI_PARAM_2_x REG_PARAM_2_x
%define REG_ABI_PARAM_2   REG_PARAM_2
%define REG_ABI_PARAM_3   REG_PARAM_3

%else
; for LINUX-x64:
%define REG_LINUX_PARAM_0_x x7
%define REG_LINUX_PARAM_0   r7
%define REG_LINUX_PARAM_1_x x6
%define REG_LINUX_PARAM_1   r6
%define REG_LINUX_PARAM_2   r2
%define REG_LINUX_PARAM_3   r1
%define REG_LINUX_PARAM_4_x x8
%define REG_LINUX_PARAM_4   r8
%define REG_LINUX_PARAM_5   r9

%define REG_ABI_PARAM_0_x REG_LINUX_PARAM_0_x
%define REG_ABI_PARAM_0   REG_LINUX_PARAM_0
%define REG_ABI_PARAM_1_x REG_LINUX_PARAM_1_x
%define REG_ABI_PARAM_1   REG_LINUX_PARAM_1
%define REG_ABI_PARAM_2   REG_LINUX_PARAM_2
%define REG_ABI_PARAM_3   REG_LINUX_PARAM_3
%define REG_ABI_PARAM_4_x REG_LINUX_PARAM_4_x
%define REG_ABI_PARAM_4   REG_LINUX_PARAM_4
%define REG_ABI_PARAM_5   REG_LINUX_PARAM_5

%macro MY_ABI_LINUX_TO_WIN_2 0
        mov     r2, r6
        mov     r1, r7
%endmacro

%macro MY_ABI_LINUX_TO_WIN_3 0
        mov     r8, r2
        mov     r2, r6
        mov     r1, r7
%endmacro

%macro MY_ABI_LINUX_TO_WIN_4 0
        mov     r9, r1
        mov     r8, r2
        mov     r2, r6
        mov     r1, r7
%endmacro

%endif ; IS_LINUX


%macro MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11 0
    %if ABI == LINUX
        MY_PUSH_2_REGS
    %else
        MY_PUSH_4_REGS
    %endif
%endmacro

%macro MY_POP_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11 0
    %if ABI == LINUX
        MY_POP_2_REGS
    %else
        MY_POP_4_REGS
    %endif
%endmacro


%macro MY_PUSH_PRESERVED_ABI_REGS 0
    MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
        push    r12
        push    r13
        push    r14
        push    r15
%endmacro


%macro MY_POP_PRESERVED_ABI_REGS 0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
    MY_POP_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
%endmacro

%endif ; x64


%macro MOVZXLOHI 3 ; dest, src, suffix
    %assign n %find(%2,x0,x1,x2,x3,x4,x5,x6,x7,x8,x9)
    %if n == 0
        %fatal <MOVZXLOHI_src_param_IS_INCORRECT>
    %else
        ; x<n>  ==>  x<n>_L or x<n>_H
        movzx   %1, %tok(%strcat("x", %eval(n-1), %3))
    %endif
%endmacro

%macro MOVZXLO 2 ; dest, src
    MOVZXLOHI  %1, %2, "_L"
%endmacro

%macro MOVZXHI 2 ; dest, src
    MOVZXLOHI  %1, %2, "_H"
%endmacro


%define mod           %%
%define AddNum(x, n)  %tok(%strcat(x, %eval(n)))
%define XMM_REG(n)    AddNum(xmm, n)
%define YMM_REG(n)    AddNum(ymm, n)


%macro XMMOP 3-4 ; op, reg1, reg2
    %if %0 == 4
        %1 XMM_REG(%2), XMM_REG(%3), %4
    %else
        %1 XMM_REG(%2), XMM_REG(%3)
    %endif
%endmacro


%assign labelnum   0
%define anonlabel  "..@mylabel_"

; automatically numbered label
%macro @@ 1
    %ifnidn %1, :
        %fatal <LABEL_WITHOUT_COLON>
    %endif
    AddNum(anonlabel, labelnum)%1
    %assign labelnum labelnum+1
%endmacro

%define @F  AddNum(anonlabel, labelnum)   ; forward to next @@ label
%define @B  AddNum(anonlabel, labelnum-1) ; back to previous @@ label

