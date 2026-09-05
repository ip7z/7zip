// TransposeFilter.cpp -- filtre de transposition par octet pour enregistrements de taille fixe

#include "StdAfx.h"

#include "../../../C/Transpose.h"

#include "../../Common/MyBuffer.h"
#include "../../Common/MyCom.h"

#include "../ICoder.h"

#include "../Common/RegisterCodec.h"

namespace NCompress {
namespace NTranspose {

struct CTranspose
{
  // _R == 0 : mode AUTOMATIQUE, la periode sera devinee sur les premieres
  // donnees vues puis figee pour tout le flux.
  unsigned _R;
  unsigned _stepExp;
  unsigned _requestedR;
  unsigned _exp;          // budget de bloc cote encodeur, pas une propriete du flux
  unsigned _measure;      // 0 = heuristique (rapide), 1 = on mesure vraiment
  CByteBuffer _tmp;
  CTranspose(): _R(0), _stepExp(0), _requestedR(0), _exp(TRANSPOSE_EXP_DEF), _measure(0) {}
  Byte *Tmp(size_t need)
  {
    if (_tmp.Size() < need)
      _tmp.Alloc(need);
    return (Byte *)_tmp;
  }
};

#ifndef Z7_EXTRACT_ONLY

class CEncoder Z7_final:
  public ICompressFilter,
  public ICompressSetCoderProperties,
  public ICompressSetCoderPropertiesOpt,
  public ICompressWriteCoderProperties,
  public CMyUnknownImp,
  CTranspose
{
  Z7_IFACES_IMP_UNK_4(
      ICompressFilter,
      ICompressSetCoderProperties,
      ICompressSetCoderPropertiesOpt,
      ICompressWriteCoderProperties)
};

// 7-Zip annonce ici la taille du flux a venir : c'est ce qui permet de choisir
// une taille de bloc adaptee plutot qu'une constante unique.
Z7_COM7F_IMF(CEncoder::SetCoderPropertiesOpt(const PROPID *propIDs, const PROPVARIANT *props, UInt32 numProps))
{
  for (UInt32 i = 0; i < numProps; i++)
    if (propIDs[i] == NCoderPropID::kExpectedDataSize && props[i].vt == VT_UI8)
      _exp = Transpose_PickExp(props[i].uhVal.QuadPart);
  return S_OK;
}

Z7_COM7F_IMF(CEncoder::Init())
{
  _R = _requestedR;
  if (_R) _stepExp = Transpose_StepExp(_R, _exp);
  return S_OK;
}

Z7_COM7F_IMF2(UInt32, CEncoder::Filter(Byte *data, UInt32 size))
{
  // Mode automatique : on devine la periode sur le premier bloc vu, puis on la
  // fige. 7-Zip (v23+) reecrit les proprietes du codec APRES Code(), donc le R
  // decouvert ici sera bien inscrit dans l'archive.
  if (_R == 0)
  {
    // On ne fige la decision qu'avec assez de donnees sous les yeux ; sinon on
    // rend la main pour etre rappele avec un tampon plus grand. Le seuil est
    // la taille de bloc choisie, pas l'echantillon d'analyse : un petit
    // fichier doit pouvoir beneficier du filtre lui aussi.
    if (size < ((SizeT)1 << _exp))
      return 0;
    _R = _measure ? Transpose_MeasureR(data, size, _exp,
                        (_measure == 2) ? TRANSPOSE_PROBE_LZMA : TRANSPOSE_PROBE_PPMD)
                  : Transpose_DetectR(data, size);
    _stepExp = Transpose_StepExp(_R, _exp);
  }

  // Aucune periode franche : on ne touche a rien. Le filtre est alors neutre
  // et ne peut pas degrader la compression.
  if (_R == 1)
    return size;

  // en dessous d'un bloc complet, on ne convertit rien
  if (_R == 0 || size < ((SizeT)_R << _stepExp))
    return 0;
  const SizeT used = Transpose_Convert(_R, _stepExp, data, size, Tmp(TRANSPOSE_BLOCK), 1);
  return (UInt32)used;
}

Z7_COM7F_IMF(CEncoder::SetCoderProperties(const PROPID *propIDs, const PROPVARIANT *props, UInt32 numProps))
{
  unsigned R = 0;
  for (UInt32 i = 0; i < numProps; i++)
  {
    const PROPVARIANT &prop = props[i];
    const PROPID propID = propIDs[i];
    if (propID >= NCoderPropID::kReduceSize)
      continue;
    if (prop.vt != VT_UI4)
      return E_INVALIDARG;
    switch (propID)
    {
      case NCoderPropID::kDefaultProp:
        if (prop.ulVal < TRANSPOSE_MIN_R || prop.ulVal > TRANSPOSE_MAX_R)
          return E_INVALIDARG;
        R = prop.ulVal;
        break;
      case NCoderPropID::kAlgorithm:
        // a=0 : heuristique rapide. Elle se trompe lourdement (mesure : 13 cas
        //       sur 40, jusqu'a +2245 %). Ne pas l'utiliser par defaut.
        // a=1 : on MESURE sur l'echantillon vu par le filtre, sonde PPMd.
        // a=2 : idem, sonde LZMA.
        // a=3 : on decide dans une passe prealable sur le fichier ENTIER.
        //       Normalement Update.cpp resout a=3 en un R concret avant que le
        //       filtre ne le voie. Si le filtre le recoit quand meme — cas d'un
        //       7zFM/7zG d'origine, sans la passe — on retombe sur a=1 plutot
        //       que d'echouer : moins bon, mais fonctionnel.
        if (prop.ulVal > 3)
          return E_INVALIDARG;
        _measure = (prop.ulVal == 3) ? 1 : prop.ulVal;
        break;
      case NCoderPropID::kNumThreads: break;
      case NCoderPropID::kLevel: break;
      default: return E_INVALIDARG;
    }
  }
  _requestedR = _R = R;
  return S_OK;
}

Z7_COM7F_IMF(CEncoder::WriteCoderProperties(ISequentialOutStream *outStream))
{
  // _R == 0 signifie que Filter() n'a jamais rien vu (flux vide) : on inscrit
  // l'identite, jamais une valeur non initialisee.
  const unsigned r = (_R == 0) ? 1 : _R;
  Byte prop[2];
  prop[0] = (Byte)(r - 1);
  prop[1] = (Byte)(_R ? _stepExp : 0);
  return outStream->Write(prop, 2, NULL);
}

#endif

class CDecoder Z7_final:
  public ICompressFilter,
  public ICompressSetDecoderProperties2,
  public CMyUnknownImp,
  CTranspose
{
  Z7_IFACES_IMP_UNK_2(
      ICompressFilter,
      ICompressSetDecoderProperties2)
};

Z7_COM7F_IMF(CDecoder::Init()) { return S_OK; }

Z7_COM7F_IMF2(UInt32, CDecoder::Filter(Byte *data, UInt32 size))
{
  if (_R == 1)
    return size;
  if (_R == 0) return 0;
  if (size < ((SizeT)_R << _stepExp))
    return 0;
  const SizeT used = Transpose_Convert(_R, _stepExp, data, size, Tmp(TRANSPOSE_BLOCK), 0);
  return (UInt32)used;
}

Z7_COM7F_IMF(CDecoder::SetDecoderProperties2(const Byte *props, UInt32 size))
{
  // New allocated method ID: exactly two bytes, no legacy property layouts.
  _R = 0;
  if (size != 2 || props[1] > TRANSPOSE_EXP_MAX)
    return E_INVALIDARG;
  const unsigned R = (unsigned)props[0] + 1;
  if (((SizeT)R << props[1]) > TRANSPOSE_BLOCK)
    return E_INVALIDARG;
  _R = R;
  _stepExp = props[1];
  return S_OK;
}

// Allocated by Igor Pavlov in https://github.com/ip7z/7zip/pull/245.
#define Z7_ID_TRANSPOSE 0x04F71301

REGISTER_FILTER_E(Transpose,
    CDecoder(),
    CEncoder(),
    Z7_ID_TRANSPOSE, "Transpose")

}}
