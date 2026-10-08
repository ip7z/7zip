/* Lz4Dec.c -- LZ4 Decoder
2025 : Igor Pavlov : Public domain */

#include "Precomp.h"

#include <string.h>

#include "Lz4Dec.h"

/*
LZ4 block format:
  A block is composed of sequences.
  Each sequence: [token][literals][match]

  Token (1 byte):
    - High 4 bits: literal length (0-15, 15 means more bytes follow)
    - Low 4 bits: match length - 4 (0-15, 15 means more bytes follow)

  If literal length == 15, read additional bytes until byte < 255
  Literals: raw bytes

  Match:
    - Offset: 2 bytes little-endian (must be > 0)
    - If match length field == 15, read additional bytes until byte < 255
    - Actual match length = field value + 4

  Last sequence has no match (ends after literals)
*/

SRes Lz4Dec_DecodeBlock(
    const Byte *src, SizeT srcLen,
    Byte *dest, SizeT *destLen,
    SizeT *srcConsumed)
{
  const Byte *srcEnd = src + srcLen;
  const Byte *srcStart = src;
  Byte *destStart = dest;
  Byte *destEnd = dest + *destLen;

  *srcConsumed = 0;
  *destLen = 0;

  while (src < srcEnd)
  {
    unsigned token;
    SizeT litLen;
    SizeT matchLen;

    // Read token
    token = *src++;
    litLen = token >> 4;
    matchLen = token & 0x0F;

    // Extended literal length
    if (litLen == 15)
    {
      for (;;)
      {
        unsigned b;
        if (src >= srcEnd)
          return SZ_ERROR_INPUT_EOF;
        b = *src++;
        litLen += b;
        if (b != 255)
          break;
      }
    }

    // Copy literals (non-overlapping)
    if (litLen > 0)
    {
      if (src + litLen > srcEnd)
        return SZ_ERROR_INPUT_EOF;
      if (dest + litLen > destEnd)
        return SZ_ERROR_OUTPUT_EOF;

      memcpy(dest, src, litLen);
      src += litLen;
      dest += litLen;
    }

    // Is last sequence ? (no match)
    if (src >= srcEnd)
      break;

    // Read match offset (2 bytes, little-endian)
    {
      SizeT offset;
      const Byte *matchSrc;

      if (src + 2 > srcEnd)
        return SZ_ERROR_INPUT_EOF;

      offset = (SizeT)src[0] | ((SizeT)src[1] << 8);
      src += 2;

      if (offset == 0)
        return SZ_ERROR_DATA; // Offset 0 is invalid

      // Extended match length
      matchLen += 4; // Minimum match length is 4

      if ((token & 0x0F) == 15)
      {
        for (;;)
        {
          unsigned b;
          if (src >= srcEnd)
            return SZ_ERROR_INPUT_EOF;
          b = *src++;
          matchLen += b;
          if (b != 255)
            break;
        }
      }

      // Validate offset
      if (offset > (SizeT)(dest - destStart))
        return SZ_ERROR_DATA; // Offset too large

      // Copy match
      if (dest + matchLen > destEnd)
        return SZ_ERROR_OUTPUT_EOF;

      matchSrc = dest - offset;

      // Handle overlapping copies
      {
        SizeT i;
        for (i = 0; i < matchLen; i++)
          dest[i] = matchSrc[i];
      }
      dest += matchLen;
    }
  }

  *srcConsumed = (SizeT)(src - srcStart);
  *destLen = (SizeT)(dest - destStart);
  return SZ_OK;
}
