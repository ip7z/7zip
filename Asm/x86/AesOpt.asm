; AesOpt.asm -- AES optimized code for x86 AES hardware instructions
; 2021-12-25 : Igor Pavlov : Public domain

%include "7zAsm.inc"


MY_ASM_START



%define use_vaes_256 1

%define NUM_AES_KEYS_MAX 15

; the number of push operators in function PROLOG
%define num_regs_push       2
%define stack_param_offset  (REG_SIZE * (1 + num_regs_push))

%if XBITS == 64
    %define num_param  REG_ABI_PARAM_2
%else
  %if IS_CDECL == 1
    ;   size_t     size
    ;   void *     data
    ;   UInt32 *   aes
    ;   ret-ip <- (r4)
    %define aes_OFFS   (stack_param_offset)
    %define data_OFFS  (REG_SIZE + aes_OFFS)
    %define size_OFFS  (REG_SIZE + data_OFFS)
    %define num_param  [r4 + size_OFFS]
  %else
    %define num_param  [r4 + stack_param_offset]
  %endif
%endif

%define keys      REG_PARAM_0  ; r1
%define rD        REG_PARAM_1  ; r2
%define rN        r0

%define koffs_x   x7
%define koffs_r   r7

%define ksize_x   x6
%define ksize_r   r6

%define keys2     r3

%define state     xmm0
%define key       xmm0
%define key_ymm   ymm0
%define key_ymm_n 0

%if XBITS == 64
        %define ways 11
%else
        %define ways 4
%endif

%define ways_start_reg 1

%define iv          XMM_REG(ways_start_reg + ways)
%define iv_ymm      YMM_REG(ways_start_reg + ways)



%if (ABI == WINDOWS) && (XBITS == 64)

; we use 32 bytes of home space in stack in WIN64-x64
%define NUM_HOME_MM_REGS   (32 / 16)
; we preserve xmm registers starting from xmm6 in WIN64-x64
%define MM_START_SAVE_REG  6

%macro SAVE_XMM 1 ; num_used_mm_regs
  %assign num_save_mm_regs  %1 - MM_START_SAVE_REG

  %if num_save_mm_regs > 0
    %assign num_save_mm_regs2   num_save_mm_regs - NUM_HOME_MM_REGS
    ; RSP is (16*x + 8) after entering the function in WIN64-x64
    %assign stack_offset        16 * num_save_mm_regs2 + (stack_param_offset mod 16)

    %assign i 0
    %rep num_save_mm_regs
      %if i == NUM_HOME_MM_REGS
        sub     r4, stack_offset
      %endif

      %if i < NUM_HOME_MM_REGS
        movdqa  [r4 + stack_param_offset + i * 16], XMM_REG(MM_START_SAVE_REG + i)
      %else
        movdqa  [r4 + (i - NUM_HOME_MM_REGS) * 16], XMM_REG(MM_START_SAVE_REG + i)
      %endif

      %assign i i+1
    %endrep
  %endif
%endmacro

%macro RESTORE_XMM 1 ; num_used_mm_regs
  %assign num_save_mm_regs  %1 - MM_START_SAVE_REG

  %if num_save_mm_regs > 0
    %assign num_save_mm_regs2   num_save_mm_regs - NUM_HOME_MM_REGS
    %assign stack_offset        16 * num_save_mm_regs2 + (stack_param_offset mod 16)

    %assign i 0
    %if num_save_mm_regs2 > 0
      %rep num_save_mm_regs2
        movdqa  XMM_REG(MM_START_SAVE_REG + NUM_HOME_MM_REGS + i), [r4 + i * 16]
        %assign i i+1
      %endrep
        add     r4, stack_offset
    %endif

    %assign num_low_regs num_save_mm_regs-i
    %assign i 0
      %rep num_low_regs
        movdqa  XMM_REG(MM_START_SAVE_REG + i), [r4 + stack_param_offset + i * 16]
        %assign i i+1
      %endrep
  %endif
%endmacro

%endif ; win64


%macro MY_PROLOG 1 ; num_used_mm_regs
        ; num_regs_push: must be equal to the number of push operators
        ; push    r3
        ; push    r5
    %if (ABI == WINDOWS) || (XBITS == 32)
        push    r6
        push    r7
    %endif

        mov     rN, num_param  ; don't move it; num_param can use stack pointer (r4)

    %if XBITS == 32
      %if IS_CDECL == 1
        mov     rD,   [r4 + data_OFFS]
        mov     keys, [r4 + aes_OFFS]
      %endif
    %elif ABI == LINUX
        MY_ABI_LINUX_TO_WIN_2
    %endif

    %if (ABI == WINDOWS) && (XBITS == 64)
        SAVE_XMM %1
    %endif
   
        mov     ksize_x, [keys + 16]
        shl     ksize_x, 5
%endmacro


%macro MY_EPILOG 1 ; num_used_mm_regs
    %if (ABI == WINDOWS) && (XBITS == 64)
        RESTORE_XMM %1
    %endif

    %if (ABI == WINDOWS) || (XBITS == 32)
        pop     r7
        pop     r6
    %endif
        ; pop     r5
        ; pop     r3
    MY_ENDP
%endmacro


%macro WOP 2 ; op, op2
    %assign i 0
    %rep ways
        %1      XMM_REG(ways_start_reg + i), %2
        %assign i i+1
    %endrep
%endmacro


%macro OP_KEY 2 ; op, offs
        %1      state, [keys + %2]
%endmacro

 
%macro WOP_KEY 2 ; op, offs
        movdqa  key, [keys + %2]
        WOP     %1, key
%endmacro


; ---------- AES-CBC Decode ----------


%macro WOP_DAT 1 ; op
    %assign i 0
    %rep ways
        %ifidni %1, pxor
            pxor    XMM_REG(ways_start_reg + i), [rD + i * 16]
        %else
            movdqa  [rD + i * 16], XMM_REG(ways_start_reg + i)
        %endif
        %assign i i+1
    %endrep
%endmacro

%macro WOP_DAT2 2 ; op, offs
    %assign i %2
    %rep ways - %2
        %1  XMM_REG(ways_start_reg + i), [rD + i * 16 - %2 * 16]
        %assign i i+1
    %endrep
%endmacro


; %define state0  XMM_REG(ways_start_reg)))

%define key0            XMM_REG(ways_start_reg + ways + 1)
%define key0_ymm        YMM_REG(ways_start_reg + ways + 1)

%define key_last        XMM_REG(ways_start_reg + ways + 2)
%define key_last_ymm    YMM_REG(ways_start_reg + ways + 2)
%define key_last_ymm_n  (ways_start_reg + ways + 2)

%define NUM_CBC_REGS    (ways_start_reg + ways + 3)


MY_PROC AesCbc_Decode_HW, 3
    ..@AesCbc_Decode_HW_start:
        MY_PROLOG NUM_CBC_REGS

    ..@AesCbc_Decode_HW_start_2:
        movdqa  iv, [keys]
        add     keys, 32

        movdqa  key0, [keys + 1 * ksize_r]
        movdqa  key_last, [keys]
        sub     ksize_x, 16

        jmp     .check2
    ALIGN 16
    .nextBlocks2:
        WOP_DAT2 movdqa, 0
        mov     koffs_x, ksize_x
        ; WOP_KEY pxor, ksize_r + 16
        WOP     pxor, key0
    ; ALIGN 16
    @@:
        WOP_KEY aesdec, 1 * koffs_r
        sub     koffs_r, 16
        jnz     @B
        ; WOP_KEY aesdeclast, 0
        WOP     aesdeclast, key_last
        
        pxor    XMM_REG(ways_start_reg), iv
        WOP_DAT2 pxor, 1
        movdqa  iv, [rD + ways * 16 - 16]
        WOP_DAT movdqa

        add     rD, ways * 16
    ..@AesCbc_Decode_HW_start_3:
    .check2:
        sub     rN, ways
        jnc     .nextBlocks2
        add     rN, ways

        sub     ksize_x, 16

        jmp     .check
    .nextBlock:
        movdqa  state, [rD]
        mov     koffs_x, ksize_x
        ; OP_KEY  pxor, 1 * ksize_r + 32
        pxor    state, key0
        ; movdqa  state0, [rD]
        ; movdqa  state, key0
        ; pxor    state, state0
    @@:
        OP_KEY  aesdec, 1 * koffs_r + 16
        OP_KEY  aesdec, 1 * koffs_r
        sub     koffs_r, 32
        jnz     @B
        OP_KEY  aesdec, 16
        ; OP_KEY  aesdeclast, 0
        aesdeclast state, key_last
        
        pxor    state, iv
        movdqa  iv, [rD]
        ; movdqa  iv, state0
        movdqa  [rD], state
        
        add     rD, 16
    .check:
        sub     rN, 1
        jnc     .nextBlock

        movdqa  [keys - 32], iv

        MY_EPILOG NUM_CBC_REGS




; ---------- AVX ----------


%macro MY_VAES_INSTR 3 ; cmd, dest, a
        %1  YMM_REG(%2), YMM_REG(%2), %3
%endmacro

%macro AVX__WRITE_TO_DATA 0
        %assign i 0
        %rep ways
            vmovdqu yword [rD + 32 * i], YMM_REG(ways_start_reg + i)
            %assign i i+1
        %endrep
%endmacro

%macro AVX__XOR_WITH_DATA 1
        %assign i %1
        %rep ways - %1
            MY_VAES_INSTR  vpxor, ways_start_reg + i, yword [rD + 32 * i - %1 * 16]
            %assign i i+1
        %endrep
%endmacro

%macro AVX__CTR_START 0
        %assign i 0
        %rep ways
            vpaddq  iv_ymm, iv_ymm, one_ymm
            ; vpxor   YMM_REG(ways_start_reg + i), iv_ymm, key_ymm
            vpxor   YMM_REG(ways_start_reg + i), iv_ymm, key0_ymm
            %assign i i+1
        %endrep
%endmacro

%macro MY_VAES_DEC 2 ; op, key
        %assign i 0
        %rep ways
            MY_VAES_INSTR  %1, ways_start_reg + i, %2
            %assign i i+1
        %endrep
%endmacro



MY_PROC AesCbc_Decode_HW_256, 3
%ifdef use_vaes_256
        MY_PROLOG NUM_CBC_REGS

        cmp     rN, ways * 2
        jb      ..@AesCbc_Decode_HW_start_2

        vmovdqa iv, [keys]
        add     keys, 32

        vbroadcasti128  key0_ymm, [keys + 1 * ksize_r]
        vbroadcasti128  key_last_ymm, [keys]
        sub     ksize_x, 16
        mov     koffs_x, ksize_x
        add     ksize_x, ksize_x

        %assign AVX_STACK_SUB  ((NUM_AES_KEYS_MAX + 1 - 2) * 32)
        push    keys2
        sub     r4, AVX_STACK_SUB
        ; sub     r4, 32
        ; sub     r4, ksize_r
        ; lea     keys2, [r4 + 32]
        mov     keys2, r4
        and     keys2, -32

    .broad:
        vbroadcasti128  key_ymm, [keys + 1 * koffs_r]
        vmovdqa         yword [keys2 + koffs_r * 2], key_ymm
        sub     koffs_r, 16
        jnz     .broad

        sub     rN, ways * 2

    align 16
    .nextBlock2:
        mov     koffs_x, ksize_x

    %assign i 0
    %rep ways
        vpxor   YMM_REG(ways_start_reg + i), key0_ymm, yword [rD + 32 * i]
        %assign i i+1
    %endrep

    @@:
        vmovdqa      key_ymm, yword [keys2 + koffs_r]
        MY_VAES_DEC  vaesdec, key_ymm
        sub     koffs_r, 32
        jnz     @B

        MY_VAES_DEC  vaesdeclast, key_last_ymm
        vinserti128  iv_ymm, iv_ymm, [rD], 1

        MY_VAES_INSTR  vpxor, ways_start_reg, iv_ymm
        AVX__XOR_WITH_DATA  1

        vmovdqa      iv, [rD + ways * 32 - 16]
        AVX__WRITE_TO_DATA

        add     rD, ways * 32
        sub     rN, ways * 2
        jnc     .nextBlock2
        add     rN, ways * 2

        shr     ksize_x, 1

        ; lea     r4, [r4 + 1 * ksize_r + 32]
        add     r4, AVX_STACK_SUB
        pop     keys2

        vzeroupper
        jmp     ..@AesCbc_Decode_HW_start_3
%else
        jmp     ..@AesCbc_Decode_HW_start
%endif
        MY_ENDP




    
; ---------- AES-CBC Encode ----------

%define e0    xmm1

%define CENC_START_KEY     2
%define CENC_NUM_REG_KEYS  (3 * 2)
%define CENC_LAST_KEY      (CENC_START_KEY + CENC_NUM_REG_KEYS + 0)
; %define last_key XMM_REG(CENC_START_KEY + CENC_NUM_REG_KEYS)))

MY_PROC AesCbc_Encode_HW, 3
        MY_PROLOG CENC_LAST_KEY

        movdqa  state, [keys]
        add     keys, 32

    %assign i 0
    %rep CENC_NUM_REG_KEYS
        movdqa  XMM_REG(CENC_START_KEY + i), [keys + i * 16]
        %assign i i+1
    %endrep
                                        
        add     keys, ksize_r
        neg     ksize_r
        add     ksize_r, (16 * CENC_NUM_REG_KEYS)
        ; movdqa  last_key, [keys]
        jmp     .check

    ALIGN 16
    .nextBlock:
        movdqa  e0, [rD]
        mov     koffs_r, ksize_r
        pxor    e0, XMM_REG(CENC_START_KEY)
        pxor    state, e0

    %assign i 1
    %rep CENC_NUM_REG_KEYS - 1
        aesenc  state, XMM_REG(CENC_START_KEY + i)
        %assign i i+1
    %endrep

    @@:
        OP_KEY  aesenc, 1 * koffs_r
        OP_KEY  aesenc, 1 * koffs_r + 16
        add     koffs_r, 32
        jnz     @B
        OP_KEY  aesenclast, 0
        ; aesenclast state, last_key
        
        movdqa  [rD], state
        add     rD, 16
    .check:
        sub     rN, 1
        jnc     .nextBlock

        ; movdqa  [keys - 32], state
        movdqa  [keys + 1 * ksize_r - (16 * CENC_NUM_REG_KEYS) - 32], state

        MY_EPILOG CENC_LAST_KEY



    
; ---------- AES-CTR ----------

%define one            XMM_REG(ways_start_reg + ways + 1)
%define one_ymm        YMM_REG(ways_start_reg + ways + 1)
%define key0           XMM_REG(ways_start_reg + ways + 2)
%define key0_ymm       YMM_REG(ways_start_reg + ways + 2)
%define NUM_CTR_REGS          (ways_start_reg + ways + 3)


MY_PROC AesCtr_Code_HW, 3
    ..@Ctr_start:
        MY_PROLOG NUM_CTR_REGS

    ..@Ctr_start_2:
        movdqa  iv, [keys]
        add     keys, 32
        movdqa  key0, [keys]

        add     keys, ksize_r
        neg     ksize_r
        add     ksize_r, 16

    ..@Ctr_start_3:
        mov     koffs_x, 1
        movd    one, koffs_x
        jmp     .check2

    ALIGN 16
    .nextBlocks2:
    %assign i 0
    %rep ways
        paddq   iv, one
        movdqa  XMM_REG(ways_start_reg + i), iv
        %assign i i+1
    %endrep
        mov     koffs_r, ksize_r
        ; WOP_KEY pxor, 1 * koffs_r -16
        WOP     pxor, key0
    @@:
        WOP_KEY aesenc, 1 * koffs_r
        add     koffs_r, 16
        jnz     @B
        WOP_KEY aesenclast, 0
        WOP_DAT pxor
        WOP_DAT movdqa
        add     rD, ways * 16
    .check2:
        sub     rN, ways
        jnc     .nextBlocks2
        add     rN, ways

        sub     keys, 16
        add     ksize_r, 16

        jmp     .check

    ; ALIGN 16
    .nextBlock:
        paddq   iv, one
        ; movdqa  state, [keys + 1 * koffs_r - 16]
        movdqa  state, key0
        mov     koffs_r, ksize_r
        pxor    state, iv

    @@:
        OP_KEY  aesenc, 1 * koffs_r
        OP_KEY  aesenc, 1 * koffs_r + 16
        add     koffs_r, 32
        jnz     @B
        OP_KEY  aesenc, 0
        OP_KEY  aesenclast, 16

        pxor    state, [rD]
        movdqa  [rD], state
        add     rD, 16
    .check:
        sub     rN, 1
        jnc     .nextBlock

        ; movdqa  [keys - 32], iv
        movdqa  [keys + 1 * ksize_r - 16 - 32], iv

        MY_EPILOG NUM_CTR_REGS


MY_PROC AesCtr_Code_HW_256, 3
%ifdef use_vaes_256
        MY_PROLOG NUM_CTR_REGS

        cmp    rN, ways * 2
        jb     ..@Ctr_start_2

        vbroadcasti128  iv_ymm, [keys]
        add     keys, 32
        vbroadcasti128  key0_ymm, [keys]
        mov     koffs_x, 1
        vmovd           one, koffs_x
        vpsubq  iv_ymm, iv_ymm, one_ymm
        vpaddq  one, one, one
        vinserti128   one_ymm, one_ymm, one, 1

        add     keys, ksize_r
        sub     ksize_x, 16
        neg     ksize_r
        mov     koffs_r, ksize_r
        add     ksize_r, ksize_r

        %assign AVX_STACK_SUB  ((NUM_AES_KEYS_MAX + 1 - 1) * 32)
        push    keys2
        lea     keys2, [r4 - 32]
        sub     r4, AVX_STACK_SUB
        and     keys2, -32
        vbroadcasti128  key_ymm, [keys]
        vmovdqa         yword [keys2], key_ymm
    @@:
        vbroadcasti128  key_ymm, [keys + 1 * koffs_r]
        vmovdqa         yword [keys2 + koffs_r * 2], key_ymm
        add     koffs_r, 16
        jnz     @B

        sub     rN, ways * 2

    ALIGN 16
    .nextBlock2:
        mov     koffs_r, ksize_r
        AVX__CTR_START

    @@:
        vmovdqa key_ymm, yword [keys2 + koffs_r]
        MY_VAES_DEC  vaesenc, key_ymm

        add     koffs_r, 32
        jnz     @B

        vmovdqa key_ymm, yword [keys2]
        MY_VAES_DEC  vaesenclast, key_ymm

        AVX__XOR_WITH_DATA 0
        AVX__WRITE_TO_DATA

        add     rD, ways * 32
        sub     rN, ways * 2
        jnc     .nextBlock2
        add     rN, ways * 2

        vextracti128    iv, iv_ymm, 1
        sar     ksize_r, 1

        add     r4, AVX_STACK_SUB
        pop     keys2

        vzeroupper
        jmp     ..@Ctr_start_3
%else
        jmp     ..@Ctr_start
%endif
        MY_ENDP

