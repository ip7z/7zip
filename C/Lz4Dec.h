/* Lz4Dec.h -- LZ4 Decoder
2025 : Igor Pavlov : Public domain */

#ifndef Z7_LZ4_DEC_H
#define Z7_LZ4_DEC_H

#include "7zTypes.h"

EXTERN_C_BEGIN

/*
LZ4 block decoder
Returns:
  SZ_OK - success
  SZ_ERROR_DATA - data error
  SZ_ERROR_INPUT_EOF - need more input
  SZ_ERROR_OUTPUT_EOF - need more output space
*/

SRes Lz4Dec_DecodeBlock(
    const Byte *src, SizeT srcLen,
    Byte *dest, SizeT *destLen,
    SizeT *srcConsumed);

EXTERN_C_END

#endif
