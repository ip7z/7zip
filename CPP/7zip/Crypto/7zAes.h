// 7zAes.h

#ifndef ZIP7_INC_CRYPTO_7Z_AES_H
#define ZIP7_INC_CRYPTO_7Z_AES_H

#include "../../Common/MyCom.h"

#include "../ICoder.h"
#include "../IPassword.h"

#include "7zKeyDerivation.h"

namespace NCrypto {
namespace N7z {

using CKeyInfo = N7zKeyDerivation::CKeyInfo;
using CKeyInfoCache = N7zKeyDerivation::CKeyInfoCache;

using N7zKeyDerivation::kKeySize;

const unsigned kIvSizeMax = 16;

class CBase
{
  CKeyInfoCache _cachedKeys;
protected:
  CKeyInfo _key;
  Byte _iv[kIvSizeMax];
  unsigned _ivSize;
  
  void PrepareKey();
  CBase();
  ~CBase()
  {
    Z7_memset_0_ARRAY(_iv);
  }
};

class CBaseCoder:
  public ICompressFilter,
  public ICryptoSetPassword,
  public CMyUnknownImp,
  public CBase
{
  Z7_IFACE_COM7_IMP(ICompressFilter)
  Z7_IFACE_COM7_IMP(ICryptoSetPassword)
protected:
  virtual ~CBaseCoder() {}
  CMyComPtr<ICompressFilter> _aesFilter;
};

#ifndef Z7_EXTRACT_ONLY

class CEncoder Z7_final:
  public CBaseCoder,
  public ICompressWriteCoderProperties,
  public ICryptoResetInitVector
{
  Z7_COM_UNKNOWN_IMP_4(
      ICompressFilter,
      ICryptoSetPassword,
      ICompressWriteCoderProperties,
      ICryptoResetInitVector)
  Z7_IFACE_COM7_IMP(ICompressWriteCoderProperties)
  Z7_IFACE_COM7_IMP(ICryptoResetInitVector)
public:
  CEncoder();
};

#endif

class CDecoder Z7_final:
  public CBaseCoder,
  public ICompressSetDecoderProperties2
{
  Z7_COM_UNKNOWN_IMP_3(
      ICompressFilter,
      ICryptoSetPassword,
      ICompressSetDecoderProperties2)
  Z7_IFACE_COM7_IMP(ICompressSetDecoderProperties2)
public:
  CDecoder();
};

}}

#endif
