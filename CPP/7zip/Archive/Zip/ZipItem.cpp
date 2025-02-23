// Archive/ZipItem.cpp

#ifndef _WIN32
#include <iconv.h>
#include <locale.h>
#include <cstdio>
#include <cstdlib>
#endif

#include "StdAfx.h"

#include "../../../../C/CpuArch.h"
#include "../../../../C/7zCrc.h"

#include "../../../Common/IntToString.h"
#include "../../../Common/MyLinux.h"
#include "../../../Common/StringConvert.h"

#include "../../../Windows/PropVariantUtils.h"

#include "../Common/ItemNameUtils.h"

#include "ZipItem.h"

namespace NArchive {
namespace NZip {

using namespace NFileHeader;


/*
const char *k_SpecName_NTFS_STREAM = "@@NTFS@STREAM@";
const char *k_SpecName_MAC_RESOURCE_FORK = "@@MAC@RESOURCE-FORK@";
*/

static const CUInt32PCharPair g_ExtraTypes[] =
{
  { NExtraID::kZip64, "Zip64" },
  { NExtraID::kNTFS, "NTFS" },
  { NExtraID::kUnix0, "UNIX" },
  { NExtraID::kStrongEncrypt, "StrongCrypto" },
  { NExtraID::kUnixTime, "UT" },
  { NExtraID::kUnix1, "UX" },
  { NExtraID::kUnix2, "Ux" },
  { NExtraID::kUnixN, "ux" },
  { NExtraID::kIzUnicodeComment, "uc" },
  { NExtraID::kIzUnicodeName, "up" },
  { NExtraID::kIzNtSecurityDescriptor, "SD" },
  { NExtraID::kWzAES, "WzAES" },
  { NExtraID::kApkAlign, "ApkAlign" }
};

void CExtraSubBlock::PrintInfo(AString &s) const
{
  for (unsigned i = 0; i < Z7_ARRAY_SIZE(g_ExtraTypes); i++)
  {
    const CUInt32PCharPair &pair = g_ExtraTypes[i];
    if (pair.Value == ID)
    {
      s += pair.Name;
      if (ID == NExtraID::kUnixTime)
      {
        if (Data.Size() >= 1)
        {
          s.Add_Colon();
          const Byte flags = Data[0];
          if (flags & 1) s.Add_Char('M');
          if (flags & 2) s.Add_Char('A');
          if (flags & 4) s.Add_Char('C');
          const UInt32 size = (UInt32)(Data.Size()) - 1;
          if (size % 4 == 0)
          {
            s.Add_Colon();
            s.Add_UInt32(size / 4);
          }
        }
      }
      /*
      if (ID == NExtraID::kApkAlign && Data.Size() >= 2)
      {
        char sz[32];
        sz[0] = ':';
        ConvertUInt32ToHex(GetUi16(Data), sz + 1);
        s += sz;
        for (unsigned j = 2; j < Data.Size(); j++)
        {
          char sz[32];
          sz[0] = '-';
          ConvertUInt32ToHex(Data[j], sz + 1);
          s += sz;
        }
      }
      */
      return;
    }
  }
  {
    char sz[16];
    sz[0] = '0';
    sz[1] = 'x';
    ConvertUInt32ToHex(ID, sz + 2);
    s += sz;
  }
}


void CExtraBlock::PrintInfo(AString &s) const
{
  if (Error)
    s.Add_OptSpaced("Extra_ERROR");

  if (MinorError)
    s.Add_OptSpaced("Minor_Extra_ERROR");

  if (IsZip64 || IsZip64_Error)
  {
    s.Add_OptSpaced("Zip64");
    if (IsZip64_Error)
      s += "_ERROR";
  }

  FOR_VECTOR (i, SubBlocks)
  {
    s.Add_Space_if_NotEmpty();
    SubBlocks[i].PrintInfo(s);
  }
}


bool CExtraSubBlock::ExtractNtfsTime(unsigned index, FILETIME &ft) const
{
  ft.dwHighDateTime = ft.dwLowDateTime = 0;
  UInt32 size = (UInt32)Data.Size();
  if (ID != NExtraID::kNTFS || size < 32)
    return false;
  const Byte *p = (const Byte *)Data;
  p += 4; // for reserved
  size -= 4;
  while (size > 4)
  {
    UInt16 tag = GetUi16(p);
    unsigned attrSize = GetUi16(p + 2);
    p += 4;
    size -= 4;
    if (attrSize > size)
      attrSize = size;
    
    if (tag == NNtfsExtra::kTagTime && attrSize >= 24)
    {
      p += 8 * index;
      ft.dwLowDateTime = GetUi32(p);
      ft.dwHighDateTime = GetUi32(p + 4);
      return true;
    }
    p += attrSize;
    size -= attrSize;
  }
  return false;
}

bool CExtraSubBlock::Extract_UnixTime(bool isCentral, unsigned index, UInt32 &res) const
{
  /* Info-Zip :
     The central-header extra field contains the modification
     time only, or no timestamp at all.
     Size of Data is used to flag its presence or absence
     If "Flags" indicates that Modtime is present in the local header
     field, it MUST be present in the central header field, too
  */

  res = 0;
  UInt32 size = (UInt32)Data.Size();
  if (ID != NExtraID::kUnixTime || size < 5)
    return false;
  const Byte *p = (const Byte *)Data;
  const Byte flags = *p++;
  size--;
  if (isCentral)
  {
    if (index != NUnixTime::kMTime ||
        (flags & (1 << NUnixTime::kMTime)) == 0 ||
        size < 4)
      return false;
    res = GetUi32(p);
    return true;
  }
  for (unsigned i = 0; i < 3; i++)
    if ((flags & (1 << i)) != 0)
    {
      if (size < 4)
        return false;
      if (index == i)
      {
        res = GetUi32(p);
        return true;
      }
      p += 4;
      size -= 4;
    }
  return false;
}


// Info-ZIP's abandoned "Unix1 timestamps & owner ID info"

bool CExtraSubBlock::Extract_Unix01_Time(unsigned index, UInt32 &res) const
{
  res = 0;
  const unsigned offset = index * 4;
  if (Data.Size() < offset + 4)
    return false;
  if (ID != NExtraID::kUnix0 &&
      ID != NExtraID::kUnix1)
    return false;
  const Byte *p = (const Byte *)Data + offset;
  res = GetUi32(p);
  return true;
}

/*
// PKWARE's Unix "extra" is similar to Info-ZIP's abandoned "Unix1 timestamps"
bool CExtraSubBlock::Extract_Unix_Time(unsigned index, UInt32 &res) const
{
  res = 0;
  const unsigned offset = index * 4;
  if (ID != NExtraID::kUnix0 || Data.Size() < offset)
    return false;
  const Byte *p = (const Byte *)Data + offset;
  res = GetUi32(p);
  return true;
}
*/

bool CExtraBlock::GetNtfsTime(unsigned index, FILETIME &ft) const
{
  FOR_VECTOR (i, SubBlocks)
  {
    const CExtraSubBlock &sb = SubBlocks[i];
    if (sb.ID == NFileHeader::NExtraID::kNTFS)
      return sb.ExtractNtfsTime(index, ft);
  }
  return false;
}

bool CExtraBlock::GetUnixTime(bool isCentral, unsigned index, UInt32 &res) const
{
  {
    FOR_VECTOR (i, SubBlocks)
    {
      const CExtraSubBlock &sb = SubBlocks[i];
      if (sb.ID == NFileHeader::NExtraID::kUnixTime)
        return sb.Extract_UnixTime(isCentral, index, res);
    }
  }
  
  switch (index)
  {
    case NUnixTime::kMTime: index = NUnixExtra::kMTime; break;
    case NUnixTime::kATime: index = NUnixExtra::kATime; break;
    default: return false;
  }
  
  {
    FOR_VECTOR (i, SubBlocks)
    {
      const CExtraSubBlock &sb = SubBlocks[i];
      if (sb.ID == NFileHeader::NExtraID::kUnix0 ||
          sb.ID == NFileHeader::NExtraID::kUnix1)
        return sb.Extract_Unix01_Time(index, res);
    }
  }
  return false;
}


bool CLocalItem::IsDir() const
{
  return NItemName::HasTailSlash(Name, GetCodePage());
}

bool CItem::IsDir() const
{
  // FIXME: we can check InfoZip UTF-8 name at first.
  if (NItemName::HasTailSlash(Name, GetCodePage()))
    return true;
  
  Byte hostOS = GetHostOS();

  if (Size == 0 && PackSize == 0 && !Name.IsEmpty() && Name.Back() == '\\')
  {
    // do we need to use CharPrevExA?
    // .NET Framework 4.5 : System.IO.Compression::CreateFromDirectory() probably writes backslashes to headers?
    // so we support that case
    switch (hostOS)
    {
      case NHostOS::kFAT:
      case NHostOS::kNTFS:
      case NHostOS::kHPFS:
      case NHostOS::kVFAT:
        return true;
      default: break;
    }
  }

  if (!FromCentral)
    return false;
  
  UInt16 highAttrib = (UInt16)((ExternalAttrib >> 16 ) & 0xFFFF);

  switch (hostOS)
  {
    case NHostOS::kAMIGA:
      switch (highAttrib & NAmigaAttrib::kIFMT)
      {
        case NAmigaAttrib::kIFDIR: return true;
        case NAmigaAttrib::kIFREG: return false;
        default: return false; // change it throw kUnknownAttributes;
      }
    case NHostOS::kFAT:
    case NHostOS::kNTFS:
    case NHostOS::kHPFS:
    case NHostOS::kVFAT:
      return ((ExternalAttrib & FILE_ATTRIBUTE_DIRECTORY) != 0);
    case NHostOS::kAtari:
    case NHostOS::kMac:
    case NHostOS::kVMS:
    case NHostOS::kVM_CMS:
    case NHostOS::kAcorn:
    case NHostOS::kMVS:
      return false; // change it throw kUnknownAttributes;
    case NHostOS::kUnix:
      return MY_LIN_S_ISDIR(highAttrib);
    default:
      return false;
  }
}

UInt32 CItem::GetWinAttrib() const
{
  UInt32 winAttrib = 0;
  switch (GetHostOS())
  {
    case NHostOS::kFAT:
    case NHostOS::kNTFS:
      if (FromCentral)
        winAttrib = ExternalAttrib;
      break;
    case NHostOS::kUnix:
      // do we need to clear 16 low bits in this case?
      if (FromCentral)
      {
        /*
          Some programs write posix attributes in high 16 bits of ExternalAttrib
          Also some programs can write additional marker flag:
            0x8000 - p7zip
            0x4000 - Zip in MacOS
            no marker - Info-Zip

          Client code has two options to detect posix field:
            1) check 0x8000 marker. In that case we must add 0x8000 marker here.
            2) check that high 4 bits (file type bits in posix field) of attributes are not zero.
        */
        
        winAttrib = ExternalAttrib & 0xFFFF0000;
        
        // #ifndef _WIN32
        winAttrib |= 0x8000; // add posix mode marker
        // #endif
      }
      break;
    default: break;
  }
  if (IsDir()) // test it;
    winAttrib |= FILE_ATTRIBUTE_DIRECTORY;
  return winAttrib;
}

bool CItem::GetPosixAttrib(UInt32 &attrib) const
{
  // some archivers can store PosixAttrib in high 16 bits even with HostOS=FAT.
  if (FromCentral && GetHostOS() == NHostOS::kUnix)
  {
    attrib = ExternalAttrib >> 16;
    return (attrib != 0);
  }
  attrib = 0;
  if (IsDir())
    attrib = MY_LIN_S_IFDIR;
  return false;
}


bool CExtraSubBlock::CheckIzUnicode(const AString &s) const
{
  size_t size = Data.Size();
  if (size < 1 + 4)
    return false;
  const Byte *p = (const Byte *)Data;
  if (p[0] > 1)
    return false;
  if (CrcCalc(s, s.Len()) != GetUi32(p + 1))
    return false;
  size -= 5;
  p += 5;
  for (size_t i = 0; i < size; i++)
    if (p[i] == 0)
      return false;
  return Check_UTF8_Buf((const char *)(const void *)p, size, false);
}
  

void CItem::GetUnicodeString(UString &res, const AString &s, bool isComment, bool useSpecifiedCodePage, UINT codePage) const
{
  bool isUtf8 = IsUtf8();
  // bool ignore_Utf8_Errors = true;
  
  if (!isUtf8)
  {
    {
      const unsigned id = isComment ?
          NFileHeader::NExtraID::kIzUnicodeComment:
          NFileHeader::NExtraID::kIzUnicodeName;
      const CObjectVector<CExtraSubBlock> &subBlocks = GetMainExtra().SubBlocks;
      
      FOR_VECTOR (i, subBlocks)
      {
        const CExtraSubBlock &sb = subBlocks[i];
        if (sb.ID == id)
        {
          if (sb.CheckIzUnicode(s))
          {
            // const unsigned kIzUnicodeHeaderSize = 5;
            if (Convert_UTF8_Buf_To_Unicode(
                (const char *)(const void *)(const Byte *)sb.Data + 5,
                sb.Data.Size() - 5, res))
              return;
          }
          break;
        }
      }
    }
    
    if (useSpecifiedCodePage)
      isUtf8 = (codePage == CP_UTF8);
    #ifdef _WIN32
    else if (GetHostOS() == NFileHeader::NHostOS::kUnix)
    {
      /* Some ZIP archives in Unix use UTF-8 encoding without Utf8 flag in header.
         We try to get name as UTF-8.
         Do we need to do it in POSIX version also? */
      isUtf8 = true;

      /* 21.02: we want to ignore UTF-8 errors to support file paths that are mixed
          of UTF-8 and non-UTF-8 characters. */
      // ignore_Utf8_Errors = false;
      // ignore_Utf8_Errors = true;
    }
    #endif
  }
  
  #ifndef _WIN32

  // Convert OEM char set to UTF-8 if needed
  // Use system locale to select code page

  // locale -> code page translation tables generated from Wine source code

  const char *lcToOemTable[] = {
    "af_ZA", "CP850", "ar_SA", "CP720", "ar_LB", "CP720", "ar_EG", "CP720",
    "ar_DZ", "CP720", "ar_BH", "CP720", "ar_IQ", "CP720", "ar_JO", "CP720",
    "ar_KW", "CP720", "ar_LY", "CP720", "ar_MA", "CP720", "ar_OM", "CP720",
    "ar_QA", "CP720", "ar_SY", "CP720", "ar_TN", "CP720", "ar_AE", "CP720",
    "ar_YE", "CP720", "ast_ES", "CP850", "az_AZ@cyrillic", "CP866", "az_AZ", "CP857",
    "be_BY", "CP866", "bg_BG", "CP866", "br_FR", "CP850", "ca_ES", "CP850",
    "zh_CN", "CP936", "zh_TW", "CP950", "kw_GB", "CP850", "cs_CZ", "CP852",
    "cy_GB", "CP850", "da_DK", "CP850", "de_AT", "CP850", "de_LI", "CP850",
    "de_LU", "CP850", "de_CH", "CP850", "de_DE", "CP850", "el_GR", "CP737",
    "en_AU", "CP850", "en_CA", "CP850", "en_GB", "CP850", "en_IE", "CP850",
    "en_JM", "CP850", "en_BZ", "CP850", "en_PH", "CP437", "en_ZA", "CP437",
    "en_TT", "CP850", "en_US", "CP437", "en_ZW", "CP437", "en_NZ", "CP850",
    "es_PA", "CP850", "es_BO", "CP850", "es_CR", "CP850", "es_DO", "CP850",
    "es_SV", "CP850", "es_EC", "CP850", "es_GT", "CP850", "es_HN", "CP850",
    "es_NI", "CP850", "es_CL", "CP850", "es_MX", "CP850", "es_ES", "CP850",
    "es_CO", "CP850", "es_ES", "CP850", "es_PE", "CP850", "es_AR", "CP850",
    "es_PR", "CP850", "es_VE", "CP850", "es_UY", "CP850", "es_PY", "CP850",
    "et_EE", "CP775", "eu_ES", "CP850", "fa_IR", "CP720", "fi_FI", "CP850",
    "fo_FO", "CP850", "fr_FR", "CP850", "fr_BE", "CP850", "fr_CA", "CP850",
    "fr_LU", "CP850", "fr_MC", "CP850", "fr_CH", "CP850", "ga_IE", "CP437",
    "gd_GB", "CP850", "gv_IM", "CP850", "gl_ES", "CP850", "he_IL", "CP862",
    "hr_HR", "CP852", "hu_HU", "CP852", "id_ID", "CP850", "is_IS", "CP850",
    "it_IT", "CP850", "it_CH", "CP850", "iv_IV", "CP437", "ja_JP", "CP932",
    "kk_KZ", "CP866", "ko_KR", "CP949", "ky_KG", "CP866", "lt_LT", "CP775",
    "lv_LV", "CP775", "mk_MK", "CP866", "mn_MN", "CP866", "ms_BN", "CP850",
    "ms_MY", "CP850", "nl_BE", "CP850", "nl_NL", "CP850", "nl_SR", "CP850",
    "nn_NO", "CP850", "nb_NO", "CP850", "pl_PL", "CP852", "pt_BR", "CP850",
    "pt_PT", "CP850", "rm_CH", "CP850", "ro_RO", "CP852", "ru_RU", "CP866",
    "sk_SK", "CP852", "sl_SI", "CP852", "sq_AL", "CP852", "sr_RS@latin", "CP852",
    "sr_RS", "CP855", "sv_SE", "CP850", "sv_FI", "CP850", "sw_KE", "CP437",
    "th_TH", "CP874", "tr_TR", "CP857", "tt_RU", "CP866", "uk_UA", "CP866",
    "ur_PK", "CP720", "uz_UZ@cyrillic", "CP866", "uz_UZ", "CP857", "vi_VN", "CP1258",
    "wa_BE", "CP850", "zh_HK", "CP950", "zh_SG", "CP936"};

  const char *lcToAnsiTable[] = {
    "af_ZA", "CP1252", "ar_SA", "CP1256", "ar_LB", "CP1256", "ar_EG", "CP1256",
    "ar_DZ", "CP1256", "ar_BH", "CP1256", "ar_IQ", "CP1256", "ar_JO", "CP1256",
    "ar_KW", "CP1256", "ar_LY", "CP1256", "ar_MA", "CP1256", "ar_OM", "CP1256",
    "ar_QA", "CP1256", "ar_SY", "CP1256", "ar_TN", "CP1256", "ar_AE", "CP1256",
    "ar_YE", "CP1256","ast_ES", "CP1252", "az_AZ@cyrillic", "CP1251", "az_AZ", "CP1254",
    "be_BY", "CP1251", "bg_BG", "CP1251", "br_FR", "CP1252", "ca_ES", "CP1252",
    "zh_CN", "CP936",  "zh_TW", "CP950",  "kw_GB", "CP1252", "cs_CZ", "CP1250",
    "cy_GB", "CP1252", "da_DK", "CP1252", "de_AT", "CP1252", "de_LI", "CP1252",
    "de_LU", "CP1252", "de_CH", "CP1252", "de_DE", "CP1252", "el_GR", "CP1253",
    "en_AU", "CP1252", "en_CA", "CP1252", "en_GB", "CP1252", "en_IE", "CP1252",
    "en_JM", "CP1252", "en_BZ", "CP1252", "en_PH", "CP1252", "en_ZA", "CP1252",
    "en_TT", "CP1252", "en_US", "CP1252", "en_ZW", "CP1252", "en_NZ", "CP1252",
    "es_PA", "CP1252", "es_BO", "CP1252", "es_CR", "CP1252", "es_DO", "CP1252",
    "es_SV", "CP1252", "es_EC", "CP1252", "es_GT", "CP1252", "es_HN", "CP1252",
    "es_NI", "CP1252", "es_CL", "CP1252", "es_MX", "CP1252", "es_ES", "CP1252",
    "es_CO", "CP1252", "es_ES", "CP1252", "es_PE", "CP1252", "es_AR", "CP1252",
    "es_PR", "CP1252", "es_VE", "CP1252", "es_UY", "CP1252", "es_PY", "CP1252",
    "et_EE", "CP1257", "eu_ES", "CP1252", "fa_IR", "CP1256", "fi_FI", "CP1252",
    "fo_FO", "CP1252", "fr_FR", "CP1252", "fr_BE", "CP1252", "fr_CA", "CP1252",
    "fr_LU", "CP1252", "fr_MC", "CP1252", "fr_CH", "CP1252", "ga_IE", "CP1252",
    "gd_GB", "CP1252", "gv_IM", "CP1252", "gl_ES", "CP1252", "he_IL", "CP1255",
    "hr_HR", "CP1250", "hu_HU", "CP1250", "id_ID", "CP1252", "is_IS", "CP1252",
    "it_IT", "CP1252", "it_CH", "CP1252", "iv_IV", "CP1252", "ja_JP", "CP932",
    "kk_KZ", "CP1251", "ko_KR", "CP949", "ky_KG", "CP1251", "lt_LT", "CP1257",
    "lv_LV", "CP1257", "mk_MK", "CP1251", "mn_MN", "CP1251", "ms_BN", "CP1252",
    "ms_MY", "CP1252", "nl_BE", "CP1252", "nl_NL", "CP1252", "nl_SR", "CP1252",
    "nn_NO", "CP1252", "nb_NO", "CP1252", "pl_PL", "CP1250", "pt_BR", "CP1252",
    "pt_PT", "CP1252", "rm_CH", "CP1252", "ro_RO", "CP1250", "ru_RU", "CP1251",
    "sk_SK", "CP1250", "sl_SI", "CP1250", "sq_AL", "CP1250", "sr_RS@latin", "CP1250",
    "sr_RS", "CP1251", "sv_SE", "CP1252", "sv_FI", "CP1252", "sw_KE", "CP1252",
    "th_TH", "CP874", "tr_TR", "CP1254", "tt_RU", "CP1251", "uk_UA", "CP1251",
    "ur_PK", "CP1256", "uz_UZ@cyrillic", "CP1251", "uz_UZ", "CP1254", "vi_VN", "CP1258",
    "wa_BE", "CP1252", "zh_HK", "CP950", "zh_SG", "CP936"};

  bool isOem = false;
  bool isAnsi = false;

  if (!isUtf8 &&
      MadeByVersion.HostOS == NFileHeader::NHostOS::kNTFS &&
      MadeByVersion.Version >= 20) {
    isAnsi = true;
  } else 
  if (!isUtf8 &&
      (MadeByVersion.HostOS == NFileHeader::NHostOS::kNTFS ||
      MadeByVersion.HostOS == NFileHeader::NHostOS::kFAT)) {
    isOem = true;
  }

  const char *legacyCp = nullptr;
  const char *legacyCpAnsi = nullptr;

  if (isOem || isAnsi || (useSpecifiedCodePage && (codePage != 65001))) {

    int tableLen = sizeof(lcToOemTable) / sizeof(lcToOemTable[0]);
    int lcLen = 0, i;

    // Detect required code page name from current locale 
    char *lc = setlocale(LC_CTYPE, "");
    if (!lc || !lc[0]) {
      lc = getenv("LC_CTYPE");
    }

    if (lc && lc[0]) {
      // Compare up to the dot, if it exists, e.g. en_US.UTF-8
      for (lcLen = 0; lc[lcLen] != '.' && lc[lcLen] != ':' && lc[lcLen] != '\0'; ++lcLen);

      for (i = 0; i < tableLen; i += 2)
        if (strncmp(lc, (lcToOemTable[i]), lcLen) == 0) {
          legacyCp = lcToOemTable[i + 1];
          legacyCpAnsi = lcToAnsiTable[i + 1];
          break; // Stop searching once a match is found
        }

      if (!legacyCp) {
        legacyCp = "CP437";
        legacyCpAnsi = "CP1252";
      }

      char specCP[20];
      if (useSpecifiedCodePage) {
        if (codePage == 0) {
          strncpy(specCP, legacyCpAnsi, sizeof(legacyCpAnsi) - 1);
          specCP[sizeof(legacyCpAnsi) - 1] = '\0';
        }
        else if (codePage == 1) {
          strncpy(specCP, legacyCp, sizeof(legacyCp) - 1);
          specCP[sizeof(legacyCp) - 1] = '\0'; }
        else {
          snprintf(specCP, sizeof(specCP), "CP%d", codePage);
        }
      }
      
      iconv_t cd;
      if ((cd = iconv_open("UTF-8", useSpecifiedCodePage ? specCP : (isOem ? legacyCp : legacyCpAnsi))) != (iconv_t)-1) {

        AString sUtf8;

        unsigned slen = s.Len();
        char* src = s.Ptr_non_const();

        unsigned dlen = slen * 4 + 1; // (source length * 4) + null termination
        char* dst = sUtf8.GetBuf_SetEnd(dlen);
        const char* dstStart = dst;

        memset(dst, 0, dlen);

        size_t slen_size_t = static_cast<size_t>(slen);
        size_t dlen_size_t = static_cast<size_t>(dlen);
        size_t done = iconv(cd, &src, &slen_size_t, &dst, &dlen_size_t);

        if (done == (size_t)-1) {
          iconv_close(cd);

          // iconv failed. Falling back to default behavior
          MultiByteToUnicodeString2(res, s, useSpecifiedCodePage ? codePage : GetCodePage());
          return;
        }

        // Null-terminate the result
        *dst = '\0';

        iconv_close(cd);

        AString sUtf8CorrectLength;
        size_t dstCorrectLength = dst - dstStart;
        sUtf8CorrectLength.SetFrom(sUtf8, static_cast<unsigned>(dstCorrectLength));
        if (ConvertUTF8ToUnicode(sUtf8CorrectLength, res) /*|| ignore_Utf8_Errors*/)
          return;
      }
    }
  }
  #endif
  
  if (isUtf8)
  {
    ConvertUTF8ToUnicode(s, res);
    return;
  }
  
  MultiByteToUnicodeString2(res, s, useSpecifiedCodePage ? codePage : GetCodePage());
}

}}
