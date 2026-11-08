; SortTest.asm -- ASM version of HeapSort() function
; Igor Pavlov : Public domain

%include "7zAsm.inc"

MY_ASM_START

%ifndef Z7_SORT_ASM_USE_SEGMENT
; %define Z7_SORT_ASM_USE_SEGMENT 1
%endif

%ifdef Z7_SORT_ASM_USE_SEGMENT
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


%define STEP_NONE_N   0
%define STEP_1_N      1
%define STEP_2_N      2
%define STEP_BRANCH_N 3


%if XBITS == 64

%define NUM_PREFETCH_LEVELS   3 ; to prefetch 1x 64-bytes line (is good for most cases)
;%define NUM_PREFETCH_LEVELS  4 ; to prefetch 2x 64-bytes lines (better for big arrays)

%define acc            x0
%define k              r0
%define k_x            acc

%define p              r1

%define s              r2
%define s_x            x2

%define a0             x3
%define t0             a0

%define a3             x5
%define qq             a3

%define a1             x6
%define t1             a1
%define t1_r           r6

%define a2             x7
%define t2             a2

%define i              r8
%define e0             x8

%define e1             x9

%define num_last       r10
%define num_last_x     x10

%define next4_lim      r11
%define pref_lim       r12



%macro SORT_2_WITH_TEMP_REG 3 ; b0, b1, temp_reg
        mov     %3, %1
        cmp     %1, %2
        cmovae  %1, %2 ; min
        cmovae  %2, %3 ; max
%endmacro

%macro SORT 2 ; b0, b1
        SORT_2_WITH_TEMP_REG %1, %2, acc
%endmacro

%macro LOAD 2 ; dest, index
        mov     %1, [p + 4 * %2]
%endmacro

%macro STORE 2 ; reg, index
        mov     [p + 4 * %2], %1
%endmacro


%if NUM_PREFETCH_LEVELS > 3
   %define num_prefetches  (1 << (NUM_PREFETCH_LEVELS - 3))
%else
   %define num_prefetches  1
%endif

%macro PREFETCH_OP 1 ; offs
  %assign cur_offset  7 * 4    ; it's average offset in 64-bytes cache line.
; %assign cur_offset  0        ; we can use zero offset, if we are sure that array is aligned for 64-bytes.
  %rep num_prefetches
    %if 1
        prefetcht0 byte [p + %1 + cur_offset]
    %else
        mov     pref_x, dword [p + %1 + cur_offset]
    %endif
    %assign cur_offset cur_offset+64
  %endrep
%endmacro

%macro PREFETCH_MY 0
  %if 1
    %if 1
        shl     k, NUM_PREFETCH_LEVELS + 3
    %else
        ; we delay prefetch instruction to improve main loads
        shl     k, NUM_PREFETCH_LEVELS
        shl     k, 3
        ; shl     k, 0
    %endif
        PREFETCH_OP k
  %elif 1
        shl     k, 3
        PREFETCH_OP k * (1 << NUM_PREFETCH_LEVELS) ; change it
  %endif
%endmacro


%macro STEP_1 2 ; exit_label, use_prefetch
    %define use_cmov_1 1  ; set 1 for cmov, but it's slower in some cases
                          ; set 0 for LOAD after adc s, 0
        cmp     t0, t1
    %if use_cmov_1 > 0
        cmovb   t0, t1
        ; STORE   t0, k
    %endif
        adc     s, 0
    %if use_cmov_1 == 0
        LOAD    t0, s
    %endif
        cmp     qq, t0
        jae     %1
    %if 1 ; use_cmov_1 == 0
        STORE   t0, k
    %endif
    %if %2 > 0
        PREFETCH_MY
    %endif
        mov     t0, [p + s * 8]
        mov     t1, [p + s * 8 + 4]
        mov     k, s
        add     s, s                 ; slower  for some cpus
        ; lea     s, dword [s + s] ; slower for some cpus
        ; shl     s, 1               ; faster for some cpus
        ; lea     s, dword [s * 2] ; faster for some cpus
    %rep 0 ; 1000 for debug : 0 for normal
        ; number of calls in generate_stage : ~0.6 of number of items
        shl     k, 0
    %endrep
%endmacro


%macro STEP_2 2 ; exit_label, use_prefetch
    %define use_cmov_2 0  ; set 1 for cmov, but it's slower in some cases
                          ; set 0 for LOAD after adc s, 0
        cmp     t0, t1
    %if use_cmov_2 == 1
        mov     t2, t0
        cmovb   t2, t1
        ; STORE   t2, k
    %endif
        mov     t0, [p + s * 8]
        mov     t1, [p + s * 8 + 4]
        cmovb   t0, [p + s * 8 + 8]
        cmovb   t1, [p + s * 8 + 12]
        adc     s, 0
    %if use_cmov_2 == 0
        LOAD    t2, s
    %endif
        cmp     qq, t2
        jae     %1
    %if 1 ; use_cmov_2 == 0
        STORE   t2, k
    %endif
    %if %2 > 0
        PREFETCH_MY
    %endif
        mov     k, s
        ; add     s, s
        ; lea     s, [s + s]
        shl     s, 1
        ; lea     s, [s * 2]
%endmacro


%macro STEP_X 3 ; STEP_N, exit_label, use_prefetch
    %if   %1 == STEP_1_N
        STEP_1  %2, %3
    %elif %1 == STEP_2_N
        STEP_2  %2, %3
    %endif
%endmacro


%macro MOVE_SMALLEST_UP 3 ; STEP_N, use_prefetch, num_unrolls
        ; s == k * 2
        ; t0 == (p)[s]
        ; t1 == (p)[s + 1]
        cmp     k, next4_lim
        jae     %%leaves

    %rep %3
        STEP_X  %1, %%exit_2, 0
        cmp     k, next4_lim
        jae     %%leaves
    %endrep

    %if %2 > 0
        %define pref_lim_2      pref_lim
        ; lea     pref_lim, dword [num_last + 1]
        ; shr     pref_lim, NUM_PREFETCH_LEVELS + 1
        cmp     k, pref_lim_2
        jae     %%last_nodes
    %else
        %define pref_lim_2      next4_lim
    %endif

MY_ALIGN_16
%%opt_loop:
        STEP_X  %1, %%exit_2, %2
        cmp     k, pref_lim_2
        jb      %%opt_loop

%%last_nodes:
        ; k >= pref_lim_2
        ; 2 cases are possible:
        ;   case-1: num_after_prefetch_levels == 0 && next4_lim = pref_lim_2
        ;   case-2: num_after_prefetch_levels == NUM_PREFETCH_LEVELS - 1 &&
        ;        next4_lim = pref_lim_2 / (NUM_PREFETCH_LEVELS - 1)
  %if %2 > 0
    %assign yyy NUM_PREFETCH_LEVELS - 1
    %rep NUM_PREFETCH_LEVELS
      %assign yyy yyy-1
        STEP_X  %1, %%exit_2, 0
      %if yyy != 0
        cmp     k, next4_lim
        jae     %%leaves
      %else
        %exitrep
      %endif
    %endrep
  %endif

%%leaves:
        ; k >= next4_lim == (num_last + 1) / 4 must be provided by previous code.
        ;   we     have    2 nodes in (s)     level :  always
        ;   we can have some nodes in (s * 2) level :  low probability case
        ;   we     have   no nodes in (s * 4) level
        ; s == k * 2
        ; t0 == (p)[s]
        ; t1 == (p)[s + 1]
        cmp     t0, t1
        cmovb   t0, t1
        adc     s, 0
        STORE   t0, k

        ; t0 == (p)[s]
        ; s / 2 == k  : (s) is index of max item from (p)[k * 2], (p)[k * 2 + 1]
        ; we have 3 possible cases here:
        ;   s * 2 >  num_last : (s) node has no childs
        ;   s * 2 == num_last : (s) node has 1 leaf child that is last item of array
        ;   s * 2 <  num_last : (s) node has 2 leaf childs. We provide (s * 4 > num_last)
        ; we check for (s * 2 > num_last) before "cmp qq, t0" check, because
        ; we will replace conditional jump with cmov instruction later.
        lea     t1_r, dword [s + s]
        cmp     t1_r, num_last
        ja      %%exit_1 ; if (s * 2 > num_last), we have no childs : it's high probability branch
        
        ; it's low probability branch
        ; s * 2 <= num_last
        cmp     qq, t0
        jae     %%exit_2

        ; qq < t0, so we go to next level
        ; we check 1 or 2 childs in next level
        mov     t0, [p + s * 8]
        mov     k, s
        mov     s, t1_r
        cmp     t1_r, num_last
        je      @F ; (s == num_last) means that we have single child in tree

        ; (s < num_last) : so we must read both childs and select max of them.
        mov     t1, [p + k * 8 + 4]
        cmp     t0, t1
        cmovb   t0, t1
        adc     s, 0
@@:
        STORE   t0, k
%%exit_1:
        ; t0 == (p)[s],  s / 2 == k  : (s) is index of max item from (p)[k * 2], (p)[k * 2 + 1]
        cmp     qq, t0
        cmovb   k, s
%%exit_2:
        STORE   qq, k
%endmacro




%ifdef Z7_SORT_ASM_USE_SEGMENT
  ; MY_ALIGN_64
  [section .text$Z7_SORT align=64 exec]
%else
  MY_ALIGN_16
%endif

MY_PROC HeapSort, 2
    %if ABI == LINUX
        mov     p, REG_ABI_PARAM_0    ; r1 <- r7 : linux
    %endif
        mov     num_last, REG_ABI_PARAM_1  ; r10 <- r6 : linux
                                      ; r10 <- r2 : win64
        cmp     num_last, 2
        jb      .end_1

        ; MY_PUSH_PRESERVED_ABI_REGS
        MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
        push    r12

        cmp     num_last, 4
        ja      .sort_5

        LOAD    a0, 0
        LOAD    a1, 1
        SORT    a0, a1
        cmp     num_last, 3
        jb      .end_2

        LOAD    a2, 2
        je      .sort_3

        LOAD    a3, 3
        SORT    a2, a3
        SORT    a1, a3
        STORE   a3, 3
.sort_3:
        SORT    a0, a2
        SORT    a1, a2
        STORE   a2, 2
        jmp     .end_2

.sort_5:
        ; (num_last > 4) is required here
        ; if (num_last >= 6) : we will use optimized loop for leaf nodes .loop_down_1
        mov     next4_lim, num_last
        shr     next4_lim, 2

        dec     num_last
        mov     k, num_last
        shr     k, 1
        mov     i, num_last
        shr     i, 2
        test    num_last, 1
        jnz     .size_even

        ; ODD number of items. So we compare parent with single child
        LOAD    t1, num_last
        LOAD    t0, k
        SORT_2_WITH_TEMP_REG  t1, t0, t2
        STORE   t1, num_last
        STORE   t0, k
        dec     k

.size_even:
        cmp     k, i
        jbe     .loop_down ; jump for num_last == 4 case

%if 0 ; 1 for debug
        mov     r15, k
        mov     r14d, 1 ; 100
.loop_benchmark:
%endif
        ; optimized loop for leaf nodes:
        mov     t0, [p + k * 8]
        mov     t1, [p + k * 8 + 4]

MY_ALIGN_16
.loop_down_1:
        ; we compare parent with max of childs:
        ; lea     s, dword [2 * k]
        mov     s, k
        cmp     t0, t1
        cmovb   t0, t1
        adc     s, s
        LOAD    t2, k
        STORE   t0, k
        cmp     t2, t0
        cmovae  s, k
        dec     k
        ; we preload next items before STORE operation for calculated address
        mov     t0, [p + k * 8]
        mov     t1, [p + k * 8 + 4]
        STORE   t2, s
        cmp     k, i
        jne     .loop_down_1

%if 0 ; 1 for debug
        mov     k, r15
        dec     r14d
        jnz     .loop_benchmark
        ; jmp .end_debug
%endif

MY_ALIGN_16
.loop_down:
        mov     t0, [p + i * 8]
        mov     t1, [p + i * 8 + 4]
        LOAD    qq, i
        mov     k, i
        lea     s, dword [i + i]
        ; jmp .end_debug

        %assign DOWN_use_prefetch  0
        %assign DOWN_num_unrolls   0
        MOVE_SMALLEST_UP  STEP_1_N, DOWN_use_prefetch, DOWN_num_unrolls
        sub     i, 1
        jnb     .loop_down

        ; jmp .end_debug
        LOAD    e0, 0
        LOAD    e1, 1

   %define LEVEL_3_LIMIT 8   ; 8 is default, but 7 also can work

        cmp     num_last, LEVEL_3_LIMIT + 1
        jb      .main_loop_sort_5

MY_ALIGN_16
.main_loop_sort:
        ; num_last > LEVEL_3_LIMIT
        ; p[size--] = p[0];
        LOAD    qq, num_last
        STORE   e0, num_last
        mov     e0, e1

        mov     next4_lim, num_last
        shr     next4_lim, 2
        mov     pref_lim, num_last
        shr     pref_lim, NUM_PREFETCH_LEVELS + 1

        dec     num_last
%if 0   ; 1 for debug
        ; that optional optimization can improve the performance, if there are identical items in array
        ;    3 times improvement : if all items in array are identical
        ;   20%  improvement : if items are different for 1 bit only
        ; 1-10%  improvement : if items are different for (2+) bits
        ; no gain : if items are different
        cmp     qq, e1
        jae     .next_iter_main
%endif
        LOAD    e1, 2
        LOAD    t0, 3
        mov     k_x, 2
        cmp     e1, t0
        cmovb   e1, t0
        mov     t0, [p + 4 * (4 + 0)]
        mov     t1, [p + 4 * (4 + 1)]
        cmovb   t0, [p + 4 * (4 + 2)]
        cmovb   t1, [p + 4 * (4 + 3)]
        adc     k_x, 0
        ; (qq <= e1), because the tree is correctly sorted
        ; also here we could check (qq >= e1) or (qq == e1) for faster exit
        lea     s, dword [k + k]
        %assign MAIN_use_prefetch  1
        %assign MAIN_num_unrolls   0
        MOVE_SMALLEST_UP  STEP_2_N, MAIN_use_prefetch, MAIN_num_unrolls

.next_iter_main:
        cmp     num_last, LEVEL_3_LIMIT
        jne     .main_loop_sort

        ; num_last == LEVEL_3_LIMIT
.main_loop_sort_5:
        ; 4 <= num_last <= LEVEL_3_LIMIT
        ; p[size--] = p[0];
        LOAD    qq, num_last
        STORE   e0, num_last
        mov     e0, e1
        dec     num_last_x

        LOAD    e1, 2
        LOAD    t0, 3
        mov     k_x, 2
        cmp     e1, t0
        cmovb   e1, t0
        adc     k_x, 0

        lea     s_x, dword [k * 2]
        cmp     s_x, num_last_x
        ja      .exit_2

        mov     t0, [p + k * 8]
        je      .exit_1

        ; s < num_last
        mov     t1, [p + k * 8 + 4]
        cmp     t0, t1
        cmovb   t0, t1
        adc     s_x, 0
.exit_1:
        STORE   t0, k
        cmp     qq, t0
        cmovb   k_x, s_x
.exit_2:
        STORE   qq, k
        cmp     num_last_x, 3
        jne     .main_loop_sort_5

        ; num_last == 3 (real_size == 4)
        LOAD    a0, 2
        LOAD    a1, 3
        STORE   e1, 2
        STORE   e0, 3
        SORT    a0, a1
.end_2:
        STORE   a0, 0
        STORE   a1, 1
; .end_debug:
        ; MY_POP_PRESERVED_ABI_REGS
        pop     r12
        MY_POP_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
.end_1:
        MY_ENDP



%else
; ------------ x86 32-bit ------------

%define acc            x0
%define k              r0
%define k_x            acc

%define p              r1

%define num_last       r2
%define num_last_x     x2

%define a0             x3
%define t0             a0

%define a3             x5
%define i              r5
%define e0             a3

%define a1             x6
%define qq             a1

%define a2             x7
%define s              r7
%define s_x            a2


%macro SORT 2 ; b0, b1
        cmp     %2, %1
        jae     @F
    %if 1
        xchg    %1, %2
    %else
        mov     acc, %1
        mov     %1, %2 ; min
        mov     %2, acc ; max
    %endif
@@:
%endmacro

%macro LOAD 2 ; dest, index
        mov     %1, [p + 4 * %2]
%endmacro

%macro STORE 2 ; reg, index
        mov     [p + 4 * %2], %1
%endmacro


%macro STEP_1 1 ; exit_label
        mov     t0, [p + k * 8]
        cmp     t0, [p + k * 8 + 4]
        adc     s, 0
        LOAD    t0, s
        STORE   t0, k ; we lookahed stooring for most expected branch
        cmp     qq, t0
        jae     %1
        ; STORE   t0, k  ; use if
        mov     k, s
        add     s, s
        ; lea     s, dword [s + s]
        ; shl     s, 1
        ; lea     s, dword [s * 2]
%endmacro

%macro STEP_BRANCH 1 ; exit_label
        mov     t0, [p + k * 8]
        cmp     t0, [p + k * 8 + 4]
        jae     @F
        inc     s
        mov     t0, [p + k * 8 + 4]
@@:
        cmp     qq, t0
        jae     %1
        STORE   t0, k
        mov     k, s
        add     s, s
%endmacro


%macro STEP_X 2 ; STEP_N, label
    %if   %1 == STEP_1_N
        STEP_1       %2
    %elif %1 == STEP_BRANCH_N
        STEP_BRANCH  %2
    %endif
%endmacro



%macro MOVE_SMALLEST_UP 3 ; STEP_N, num_unrolls, exit_2
        ; s == k * 2
    %rep %2
        cmp     s, num_last
        jae     %%leaves
        STEP_1  %3
    %endrep
        cmp     s, num_last
        jb      %%opt_loop

%%leaves:
        ; (s >= num_last)
        jne     %3
%%single:
        ; (s == num_last)
        mov     t0, [p + k * 8]
        cmp     qq, t0
        jae     %3
        STORE   t0, k
        mov     k, s
        jmp     %3

MY_ALIGN_16
%%opt_loop:
        STEP_X  %1, %3
        cmp     s, num_last
        jb      %%opt_loop
        je      %%single
%3:
        STORE   qq, k
%endmacro




%ifdef Z7_SORT_ASM_USE_SEGMENT
; MY_ALIGN_64
%else
  MY_ALIGN_16
%endif

MY_PROC HeapSort, 2
  %if XBITS == 64
    %if ABI == LINUX
        mov     num_last, REG_ABI_PARAM_1  ; r2 <- r6 : linux
        mov     p,        REG_ABI_PARAM_0  ; r1 <- r7 : linux
    %endif
  %elif IS_CDECL > 0
        mov     num_last, [r4 + REG_SIZE * 2]
        mov     p,        [r4 + REG_SIZE * 1]
  %endif
        cmp     num_last, 2
        jb      .end_1
        MY_PUSH_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11

        cmp     num_last, 4
        ja      .sort_5

        LOAD    a0, 0
        LOAD    a1, 1
        SORT    a0, a1
        cmp     num_last, 3
        jb      .end_2

        LOAD    a2, 2
        je      .sort_3

        LOAD    a3, 3
        SORT    a2, a3
        SORT    a1, a3
        STORE   a3, 3
.sort_3:
        SORT    a0, a2
        SORT    a1, a2
        STORE   a2, 2
        jmp     .end_2

.sort_5:
        ; num_last > 4
        lea     i, dword [num_last - 2]
        dec     num_last
        test    i, 1
        jz      .loop_down

        ; single child
        mov     t0, [p + num_last * 4]
        mov     qq, [p + num_last * 2]
        dec     i
        cmp     qq, t0
        jae     .loop_down

        mov     [p + num_last * 2], t0
        mov     [p + num_last * 4], qq

MY_ALIGN_16
.loop_down:
        mov     t0, [p + i * 4]
        cmp     t0, [p + i * 4 + 4]
        mov     k, i
        mov     qq, [p + i * 2]
        adc     k, 0
        LOAD    t0, k
        cmp     qq, t0
        jae     .down_next
        mov     [p + i * 2], t0
        lea     s, dword [k + k]

        %assign DOWN_num_unrolls 0
        MOVE_SMALLEST_UP  STEP_1_N, DOWN_num_unrolls, .down_exit_label
.down_next:
        sub     i, 2
        jnb     .loop_down
        ; jmp .end_debug

        LOAD    e0, 0

MY_ALIGN_16
.main_loop_sort:
        ; num_last > 3
        mov     t0, [p + 2 * 4]
        cmp     t0, [p + 3 * 4]
        LOAD    qq, num_last
        STORE   e0, num_last
        LOAD    e0, 1
        mov     s_x, 2
        mov     k_x, 1
        adc     s, 0
        LOAD    t0, s
        dec     num_last
        cmp     qq, t0
        jae     .main_exit_label
        STORE   t0, 1
        mov     k, s
        add     s, s
    %if 1
        ; for branch data prefetch mode :
        ; it's faster for large arrays : larger than (1 << 13) items.
        %assign MAIN_num_unrolls  10
        %assign STEP_LOOP_N       STEP_BRANCH_N
    %else
        %assign MAIN_num_unrolls  0
        %assign STEP_LOOP_N       STEP_1_N
    %endif

        MOVE_SMALLEST_UP  STEP_LOOP_N, MAIN_num_unrolls, .main_exit_label

        ; jmp .end_debug
        cmp     num_last, 3
        jne     .main_loop_sort

        ; num_last == 3 (real_size == 4)
        LOAD    a0, 2
        LOAD    a1, 3
        LOAD    a2, 1
        STORE   e0, 3  ; e0 is alias for a3
        STORE   a2, 2
        SORT    a0, a1
.end_2:
        STORE   a0, 0
        STORE   a1, 1
; .end_debug:
        MY_POP_PRESERVED_ABI_REGS_UP_TO_INCLUDING_R11
.end_1:
        MY_ENDP

%endif


%if 0
LEA_IS_D8 (R64) [R2 * 4 + 16]
 Lat : TP
   2 :  1 :      adl-e
   2 :  3   p056 adl-p
   1 :  2 : p15  hsw-rocket
   1 :  2 : p01  snb-ivb
   1 :  1 : p1   conroe-wsm
   1 :  4 : zen3,zen4
   2 :  4 : zen1,zen2

LEA_B_IS (R64) [R2 + R3 * 4]
 Lat : TP
   1 :  1 :      adl-e
   2 :  3   p056 adl-p
   1 :  2 : p15  hsw-rocket
   1 :  2 : p01  snb-ivb
   1 :  1 : p1   nhm-wsm
   1 :  1 : p0   conroe-wsm
   1 :  4 : zen3,zen4
   2 :2,4 : zen1,zen2
   
LEA_B_IS_D8 (R64) [R2 + R3 * 4 + 16]
 Lat : TP
   2 :  1 :      adl-e
   2 :  3   p056 adl-p
   1 :  2 : p15  ice-rocket
   3 :  1 : p1/p15 hsw-rocket
   3 :  1 : p01  snb-ivb
   1 :  1 : p1   nhm-wsm
   1 :  1 : p0   conroe-wsm
 2,1 :  2 : zen3,zen4
   2 :  2 : zen1,zen2
   
CMOVB (R64, R64)
 Lat : TP
 1,2 :  2 :      adl-e
   1 :  2   p06  adl-p
   1 :  2 : p06  bwd-rocket
 1,2 :  2 : p0156+p06 hsw
 1,2 :1.5 : p015+p05  snb-ivb
 1,2 :  1 : p015+p05  nhm
   1 :  1 : 2*p015  conroe
   1 :  2 : zen3,zen4
   1 :  4 : zen1,zen2

ADC (R64, 0)
 Lat : TP
 1,2 :  2 :      adl-e
   1 :  2   p06  adl-p
   1 :  2 : p06  bwd-rocket
   1 :1.5 : p0156+p06 hsw
   1 :1.5 : p015+p05  snb-ivb
   2 :  1 : 2*p015    conroe-wstm
   1 :  2 : zen1,zen2,zen3,zen4
   
PREFETCHNTA : fetch data into non-temporal cache close to the processor, minimizing cache pollution.
  L1 : Pentium3
  L2 : NetBurst
  L1, not L2: Core duo, Core 2, Atom processors
  L1, not L2, may fetch into L3 with fast replacement: Nehalem, Westmere, Sandy Bridge, ...
      NEHALEM: Fills L1/L3, L1 LRU is not updated
  L3 with fast replacement: Xeon Processors based on Nehalem, Westmere, Sandy Bridge, ...
PREFETCHT0 : fetch data into all cache levels.
PREFETCHT1 : fetch data into L2 and L3
%endif

