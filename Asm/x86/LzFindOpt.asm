; LzFindOpt.asm -- ASM version of GetMatchesSpecN_2() function
; 2024-06-18: Igor Pavlov : Public domain

%include "7zAsm.inc"

%if XBITS != 64
  %fatal <x64_IS_REQUIRED>
%endif

MY_ASM_START

%define Z7_LZ_FIND_OPT_ASM_USE_SEGMENT 1

%ifdef Z7_LZ_FIND_OPT_ASM_USE_SEGMENT
%macro MY_ALIGN 1
        ALIGN  %1
%endmacro
%else
%macro MY_ALIGN 1
        ; We expect that ".text" is aligned for 16-bytes.
        ; So we don't need large alignment inside our function.
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


%define t0_L     x0_L
%define t0_x     x0
%define t0       r0
%define t1_x     x3
%define t1       r3

%define cp_x     t1_x
%define cp_r     t1
%define m        x5
%define m_r      r5
%define len_x    x6
%define len      r6
%define diff_x   x7
%define diff     r7
%define len0     r10
%define len1_x   x11
%define len1     r11
%define maxLen_x x12
%define maxLen   r12
%define d        r13
%define ptr0     r14
%define ptr1     r15

%define d_lim        m_r
%define cycSize      len_x
%define hash_lim     len0
%define delta1_x     len1_x
%define delta1_r     len1
%define delta_x      maxLen_x
%define delta_r      maxLen
%define hash         ptr0
%define src          ptr1



%if ABI == LINUX

; r1 r2  r8 r9        : win32
; r7 r6  r2 r1  r8 r9 : linux

%define lenLimit         r8
%define lenLimit_x       x8
; %define pos_r          r2
%define pos              x2
%define cur              r1
%define son              r9

%else

%define lenLimit         REG_ABI_PARAM_2
%define lenLimit_x       REG_ABI_PARAM_2_x
%define pos              REG_ABI_PARAM_1_x
%define cur              REG_ABI_PARAM_0
%define son              REG_ABI_PARAM_3

%endif


%if ABI == LINUX
    %define maxLen_OFFS      (REG_SIZE * (6 + 1))
%else
    %define cutValue_OFFS    (REG_SIZE * (8 + 1 + 4))
    %define d_OFFS           (REG_SIZE + cutValue_OFFS)
    %define maxLen_OFFS      (REG_SIZE + d_OFFS)
%endif
    %define hash_OFFS        (REG_SIZE + maxLen_OFFS)
    %define limit_OFFS       (REG_SIZE + hash_OFFS)
    %define size_OFFS        (REG_SIZE + limit_OFFS)
    %define cycPos_OFFS      (REG_SIZE + size_OFFS)
    %define cycSize_OFFS     (REG_SIZE + cycPos_OFFS)
    %define posRes_OFFS      (REG_SIZE + cycSize_OFFS)
    
%if ABI == WINDOWS
    %define cutValue_PAR     [r0 + cutValue_OFFS]
    %define d_PAR            [r0 + d_OFFS]
%endif
    %define maxLen_PAR       [r0 + maxLen_OFFS]
    %define hash_PAR         [r0 + hash_OFFS]
    %define limit_PAR        [r0 + limit_OFFS]
    %define size_PAR         [r0 + size_OFFS]
    %define cycPos_PAR       [r0 + cycPos_OFFS]
    %define cycSize_PAR      [r0 + cycSize_OFFS]
    %define posRes_PAR       [r0 + posRes_OFFS]


    %define cutValue_VAR     DWORD [r4 + 8 * 0]
    %define cutValueCur_VAR  DWORD [r4 + 8 * 0 + 4]
    %define cycPos_VAR       DWORD [r4 + 8 * 1 + 0]
    %define cycSize_VAR      DWORD [r4 + 8 * 1 + 4]
    %define hash_VAR         QWORD [r4 + 8 * 2]
    %define limit_VAR        QWORD [r4 + 8 * 3]
    %define size_VAR         QWORD [r4 + 8 * 4]
    %define distances        QWORD [r4 + 8 * 5]
    %define maxLen_VAR       QWORD [r4 + 8 * 6]

    %define Old_RSP          QWORD [r4 + 8 * 7]
    %define LOCAL_SIZE       8 * 8

%macro COPY_VAR_32 2 ; dest, src
        mov     x3, %2
        mov     %1, x3
%endmacro

%macro COPY_VAR_64 2 ; dest, src
        mov     r3, %2
        mov     %1, r3
%endmacro


%ifdef Z7_LZ_FIND_OPT_ASM_USE_SEGMENT
  ; MY_ALIGN_64
  [section .text$LZFINDOPT align=64 exec]
%else
  MY_ALIGN_16
%endif
MY_PROC GetMatchesSpecN_2, 13
        MY_PUSH_PRESERVED_ABI_REGS
        mov     r0, RSP
        lea     r3, [r0 - LOCAL_SIZE]
        and     r3, -64
        mov     RSP, r3
        mov     Old_RSP, r0

%if ABI == LINUX
        mov     d,            REG_ABI_PARAM_5       ; r13 = r9
        mov     cutValue_VAR, REG_ABI_PARAM_4_x     ;     = r8
        mov     son,          REG_ABI_PARAM_3       ;  r9 = r1
        mov     r8,           REG_ABI_PARAM_2       ;  r8 = r2
        mov     pos,          REG_ABI_PARAM_1_x     ;  r2 = x6
        mov     r1,           REG_ABI_PARAM_0       ;  r1 = r7
%else
        COPY_VAR_32 cutValue_VAR, cutValue_PAR
        mov     d, d_PAR
%endif

        COPY_VAR_64 limit_VAR, limit_PAR
        
        mov     hash_lim, size_PAR
        mov     size_VAR, hash_lim
        
        mov     cp_x, cycPos_PAR
        mov     hash, hash_PAR

        mov     cycSize, cycSize_PAR
        mov     cycSize_VAR, cycSize
        
        ; we want cur in (rcx). So we change the cur and lenLimit variables
        sub     lenLimit, cur
        neg     lenLimit_x
        inc     lenLimit_x
        
        mov     t0_x, maxLen_PAR
        sub     t0, lenLimit
        mov     maxLen_VAR, t0

        jmp     .main_loop

MY_ALIGN_64
.fill_empty:
        ; ptr0 = *ptr1 = kEmptyHashValue;
        mov     QWORD [ptr1], 0
        inc     pos
        inc     cp_x
        mov     DWORD [d - 4], 0
        cmp     d, limit_VAR
        jae     .fin
        cmp     hash, hash_lim
        je      .fin

; MY_ALIGN_64
.main_loop:
        ; UInt32 delta = *hash++;
        mov     diff_x, [hash]  ; delta
        add     hash, 4
        ; mov     cycPos_VAR, cp_x

        inc     cur
        add     d, 4
        mov     m, pos
        sub     m, diff_x;      ; matchPos

        ; CLzRef *ptr1 = son + ((size_t)(pos) << 1) - CYC_TO_POS_OFFSET * 2;
        lea     ptr1, [son + 8 * cp_r]
        ; mov     cycSize, cycSize_VAR
        cmp     pos, cycSize
        jb      .directMode      ; if (pos < cycSize_VAR)

        ; CYC MODE

        cmp     diff_x, cycSize
        jae     .fill_empty      ; if (delta >= cycSize_VAR)

        xor     t0_x, t0_x
        mov     cycPos_VAR, cp_x
        sub     cp_x, diff_x
        ; jae     .prepare_for_tree_loop
        ; add     cp_x, cycSize
        cmovb   t0_x, cycSize
        add     cp_x, t0_x      ; cp_x +=  (cycPos < delta ? cycSize : 0)
        jmp     .prepare_for_tree_loop


.directMode:
        cmp     diff_x,  pos
        je      .fill_empty      ; if (delta == pos)
        jae     .fin_error       ; if (delta >= pos)

        mov     cycPos_VAR, cp_x
        mov     cp_x, m

.prepare_for_tree_loop:
        mov     len0, lenLimit
        mov     hash_VAR, hash
        ; CLzRef *ptr0 = son + ((size_t)(pos) << 1) - CYC_TO_POS_OFFSET * 2 + 1;
        lea     ptr0, [ptr1 + 4]
        ; UInt32 *_distances = ++d;
        mov     distances, d

        neg     len0
        mov     len1, len0

        mov     t0_x, cutValue_VAR
        mov     maxLen, maxLen_VAR
        mov     cutValueCur_VAR, t0_x

MY_ALIGN_32
.tree_loop:
        neg     diff
        mov     len, len0
        cmp     len1, len0
        cmovb   len, len1       ; len = (len1 < len0 ? len1 : len0);
        add     diff, cur

        mov     t0_x, [son + cp_r * 8]  ; prefetch
        movzx   t0_x, BYTE [diff + 1 * len]
        lea     cp_r, [son + cp_r * 8]
        cmp     [cur + 1 * len], t0_L
        je      .matched_1

        jb      .left_0

        mov     [ptr1], m
        mov        m, [cp_r + 4]
        lea     ptr1, [cp_r + 4]
        sub     diff, cur ; FIX32
        jmp     .next_node

MY_ALIGN_32
.left_0:
        mov     [ptr0], m
        mov        m, [cp_r]
        mov     ptr0, cp_r
        sub     diff, cur ; FIX32
        ; jmp     .next_node

; ------------ NEXT NODE ------------
; MY_ALIGN_32
.next_node:
        mov     cycSize, cycSize_VAR
        dec     cutValueCur_VAR
        je      .finish_tree

        add     diff_x, pos     ; prev_match = pos + diff
        cmp     m, diff_x
        jae     .fin_error       ; if (new_match >= prev_match)

        mov     diff_x, pos
        sub     diff_x, m       ; delta = pos - new_match
        cmp     pos, cycSize
        jae     .cyc_mode_2      ; if (pos >= cycSize)

        mov     cp_x, m
        test    m, m
        jne     .tree_loop       ; if (m != 0)

.finish_tree:
        ; ptr0 = *ptr1 = kEmptyHashValue;
        mov     DWORD [ptr0], 0
        mov     DWORD [ptr1], 0

        inc     pos

        ; _distances[-1] = (UInt32)(d - _distances);
        mov     t0, distances
        mov     t1, d
        sub     t1, t0
        shr     t1_x, 2
        mov     [t0 - 4], t1_x

        cmp     d, limit_VAR
        jae     .fin             ; if (d >= limit)

        mov     cp_x, cycPos_VAR
        mov     hash, hash_VAR
        mov     hash_lim, size_VAR
        inc     cp_x
        cmp     hash, hash_lim
        jne     .main_loop       ; if (hash != size)
        jmp     .fin


MY_ALIGN_32
.cyc_mode_2:
        cmp     diff_x, cycSize
        jae     .finish_tree     ; if (delta >= cycSize)

        mov     cp_x, cycPos_VAR
        xor     t0_x, t0_x
        sub     cp_x, diff_x    ; cp_x = cycPos - delta
        cmovb   t0_x, cycSize
        add     cp_x, t0_x      ; cp_x += (cycPos < delta ? cycSize : 0)
        jmp     .tree_loop


MY_ALIGN_32
.matched_1:

        inc     len
        ; cmp     len_x, lenLimit_x
        je      short .lenLimit_reach
        movzx   t0_x, BYTE [diff + 1 * len]
        cmp     [cur + 1 * len], t0_L
        jne     .mismatch


MY_ALIGN_32
.match_loop:
        ;  while (++len != lenLimit)  (len[diff] != len[0]) ;

        inc     len
        ; cmp     len_x, lenLimit_x
        je      short .lenLimit_reach
        movzx   t0_x, BYTE [diff + 1 * len]
        cmp     BYTE [cur + 1 * len], t0_L
        je      .match_loop

.mismatch:
        jb      .left_2

        mov     [ptr1], m
        mov        m, [cp_r + 4]
        lea     ptr1, [cp_r + 4]
        mov     len1, len

        jmp     .max_update

MY_ALIGN_32
.left_2:
        mov     [ptr0], m
        mov        m, [cp_r]
        mov     ptr0, cp_r
        mov     len0, len

.max_update:
        sub     diff, cur       ; restore diff

        cmp     maxLen, len
        jae     .next_node

        mov     maxLen, len
        add     len, lenLimit
        mov     [d], len_x
        mov     t0_x, diff_x
        not     t0_x
        mov     [d + 4], t0_x
        add     d, 8

        jmp     .next_node


MY_ALIGN_32
.lenLimit_reach:

        mov     delta_r, cur
        sub     delta_r, diff
        lea     delta1_r, [delta_r - 1]

        mov     t0_x, [cp_r]
        mov     [ptr1], t0_x
        mov     t0_x, [cp_r + 4]
        mov     [ptr0], t0_x

        mov     [d], lenLimit_x
        mov     [d + 4], delta1_x
        add     d, 8

        ; _distances[-1] = (UInt32)(d - _distances);
        mov     t0, distances
        mov     t1, d
        sub     t1, t0
        shr     t1_x, 2
        mov     [t0 - 4], t1_x

        mov     hash, hash_VAR
        mov     hash_lim, size_VAR

        inc     pos
        mov     cp_x, cycPos_VAR
        inc     cp_x

        mov     d_lim, limit_VAR
        mov     cycSize, cycSize_VAR
        ; if (hash == size || *hash != delta || lenLimit[diff] != lenLimit[0] || d >= limit)
        ;    break;
        cmp     hash, hash_lim
        je      .fin
        cmp     d, d_lim
        jae     .fin
        cmp     delta_x, [hash]
        jne     .main_loop
        movzx   t0_x, BYTE [diff]
        cmp     [cur], t0_L
        jne     .main_loop

        ; jmp     .main_loop     ; bypass for debug

        mov     cycPos_VAR, cp_x
        shl     len, 3          ; cycSize * 8
        sub     diff, cur       ; restore diff
        xor     t0_x, t0_x
        cmp     cp_x, delta_x   ; cmp (cycPos_VAR, delta)
        lea     cp_r, [son + 8 * cp_r]  ; dest
        lea     src, [cp_r + 8 * diff]
        cmovb   t0, len         ; t0 =  (cycPos_VAR < delta ? cycSize * 8 : 0)
        add     src, t0
        add     len, son        ; len = son + cycSize * 8


MY_ALIGN_32
.long_loop:
        add     hash, 4

        ; *(UInt64 *)(void *)ptr = ((const UInt64 *)(const void *)ptr)[diff];

        mov     t0, [src]
        add     src, 8
        mov     [cp_r], t0
        add     cp_r, 8
        cmp     src, len
        cmove   src, son       ; if end of (son) buffer is reached, we wrap to begin

        mov     DWORD [d], 2
        mov     [d + 4], lenLimit_x
        mov     [d + 8], delta1_x
        add     d, 12

        inc     cur

        cmp     hash, hash_lim
        je      .long_footer
        cmp     delta_x, [hash]
        jne     .long_footer
        movzx   t0_x, BYTE [diff + 1 * cur]
        cmp     [cur], t0_L
        jne     .long_footer
        cmp     d, d_lim
        jb      .long_loop

.long_footer:
        sub     cp_r, son
        shr     cp_r, 3
        add     pos, cp_x
        sub     pos, cycPos_VAR
        mov     cycSize, cycSize_VAR

        cmp     d, d_lim
        jae     .fin
        cmp     hash, hash_lim
        jne     .main_loop
        jmp     .fin


.fin_error:
        xor     d, d

.fin:
        mov     RSP, Old_RSP
        mov     t0, [r4 + posRes_OFFS]
        mov     [t0], pos
        mov     r0, d

        MY_POP_PRESERVED_ABI_REGS
        MY_ENDP

