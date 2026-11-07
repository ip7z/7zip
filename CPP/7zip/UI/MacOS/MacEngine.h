// MacEngine.h

/*
  Interface between the 7-Zip engine (UI/Common) and the macOS GUI (Cocoa).

  This header is included from both C++ (.cpp) and Objective-C++ (.mm) files.
  It must not include 7-Zip headers or Cocoa headers:
  both define conflicting types (BOOL, for example).

  All strings are UTF-8. Paths use '/' as separator.

  The engine works in the same way as 7zG.exe in Windows:
  the GUI builds a command line in 7-Zip syntax ("a", "x", "t", "d" ...),
  and the engine parses it with CArcCmdLineParser and runs
  Extract() / UpdateArchive() from UI/Common.
  So all command line switches documented for 7-Zip can be used.
*/

#ifndef ZIP7_INC_MAC_ENGINE_H
#define ZIP7_INC_MAC_ENGINE_H

#include <stddef.h>
#include <stdint.h>

namespace NMacEngine {

// the order is the same as in NOverwriteAnswer (IFileExtractCallback.h)
enum EOverwriteAnswer
{
  kOverwrite_Yes,
  kOverwrite_YesToAll,
  kOverwrite_No,
  kOverwrite_NoToAll,
  kOverwrite_AutoRename,
  kOverwrite_Cancel
};

// the order is the same as in NExtract::NPathMode (ExtractMode.h)
enum EPathMode
{
  kPathMode_Full,
  kPathMode_Current,
  kPathMode_No,
  kPathMode_Abs
};

// the order is the same as in NExtract::NOverwriteMode (ExtractMode.h)
enum EOverwriteMode
{
  kOverwriteMode_Ask,
  kOverwriteMode_Overwrite,
  kOverwriteMode_Skip,
  kOverwriteMode_Rename,
  kOverwriteMode_RenameExisting
};

// current operation that is shown in progress window
enum EOperation
{
  kOp_None,
  kOp_Scanning,
  kOp_Opening,
  kOp_Extracting,
  kOp_Testing,
  kOp_Skipping,
  // the following values are in same order as NUpdateNotifyOp
  kOp_Add,
  kOp_Update,
  kOp_Analyze,
  kOp_Replicate,
  kOp_Repack,
  kOp_Skip,
  kOp_Delete,
  kOp_Header,
  // other operations
  kOp_Moving,
  kOp_Removing
};

struct CFileInfo
{
  bool SizeDefined;
  bool TimeDefined;
  uint64_t Size;
  int64_t UnixTime; // seconds since 1970
};

/*
  IUserCallback is implemented by the GUI.
  The engine calls it from worker thread (not from main thread).
*/

class IUserCallback
{
public:
  virtual ~IUserCallback();

  virtual void SetTotal(uint64_t total) = 0;
  virtual void SetCompleted(uint64_t completed) = 0;
  virtual void SetRatioInfo(uint64_t inSize, uint64_t outSize) = 0;
  virtual void SetNumFiles(uint64_t numFilesTotal) = 0;
  virtual void SetNumFilesCompleted(uint64_t numFiles) = 0;
  virtual void SetCurrent(EOperation op, const char *name) = 0;

  // returns true, if user has cancelled operation.
  // it blocks if user has paused operation.
  virtual bool CheckBreak() = 0;

  // returns false, if user has cancelled password dialog.
  virtual bool AskPassword(char *buf, size_t bufSize) = 0;

  virtual EOverwriteAnswer AskOverwrite(
      const char *existPath, const CFileInfo &existInfo,
      const char *newPath, const CFileInfo &newInfo) = 0;

  virtual void AddMessage(const char *message, bool isError) = 0;
};


struct CResult
{
  int32_t HResult;      // S_OK = 0, E_ABORT = 0x80004004
  uint64_t NumErrors;   // number of errors (data errors, CRC errors, open errors)
  uint64_t NumWarnings;
  uint64_t NumFiles;    // number of processed files
  uint64_t NumFolders;
  uint64_t UnpackSize;
  uint64_t ArcSize;     // size of created archive
  bool PasswordWasDefined;
  char Password[256];   // password that was entered in password dialog (UTF-8)

  void Clear();
  bool IsAborted() const { return HResult == (int32_t)0x80004004; }
};

// GetErrorMessage() returns static text for HRESULT error code.
// the returned string is valid until next call of GetErrorMessage().
const char *GetErrorMessage(int32_t hres);


// Init() loads codecs. It must be called at startup.
// langFilePath can be NULL. It is a file in 7-Zip Lang format (Lang/xx.txt).
bool Init(const char *langFilePath);

// LangString() returns translated string with (id) from 7-Zip lang file
// (the IDs are same as in Windows resources),
// or defaultString, if there is no translation.
const char *LangString(uint32_t id, const char *defaultString);

const char *GetVersion(); // "26.04"
const char *GetCopyright();
const char *GetDate();


struct CFormatInfo
{
  const char *Name;  // "7z", "zip", ...
  const char *Exts;  // "7z" "tar tgz" (space-separated, the first extension is default)
  bool CanUpdate;
  bool KeepName;     // the format compresses only one file (gzip, bzip2, xz)
};

unsigned GetNumFormats();
void GetFormatInfo(unsigned index, CFormatInfo &info);
// returns -1, if there is no format for that extension.
int FindFormatForExtension(const char *ext);
bool IsArchiveExtension(const char *ext);


/*
  RunCommand() parses and executes 7-Zip command line:
    args[0] is command (a, u, d, rn, x, e, t),
    other args are switches and file names.
  Use "--" before file names.
  It blocks until the operation is finished. Call it from worker thread.
*/
void RunCommand(const char * const *args, unsigned numArgs, IUserCallback *callback, CResult &result);


struct CItemInfo
{
  const char *Path;   // full path inside archive, '/' separated
  const char *Method; // compression method, can be empty
  uint64_t Size;
  uint64_t PackSize;
  int64_t MTime;      // unix time in seconds
  uint32_t Crc;
  uint32_t Attrib;    // Windows attributes, and POSIX mode in high 16 bits (if 0x8000 flag)
  bool IsDir;
  bool SizeDefined;
  bool PackSizeDefined;
  bool MTimeDefined;
  bool CrcDefined;
  bool AttribDefined;
  bool Encrypted;
};

struct CPropPair
{
  const char *Name;
  const char *Value;
};

/*
  IArchive : archive that is opened for browsing.
  The object can be used from different threads, but not simultaneously.
*/

class IArchive
{
public:
  virtual ~IArchive();

  virtual unsigned GetNumItems() const = 0;
  virtual const CItemInfo &GetItem(unsigned index) const = 0;

  virtual const char *GetFormatName() const = 0;
  virtual bool CanUpdate() const = 0;
  virtual bool IsEncrypted() const = 0; // there are encrypted items or headers

  // properties of archive (for "Properties" window)
  virtual unsigned GetNumProps() const = 0;
  virtual CPropPair GetProp(unsigned index) const = 0;

  // properties of one item (for "Properties" window)
  // the returned array is valid until next call.
  virtual unsigned GetItemProps(unsigned itemIndex, const CPropPair **props) = 0;

  /*
    Extract() extracts the items (indices must be sorted).
    prefix : the path prefix in archive ("dir1/dir2/") that will be removed
             from item paths. It's used to extract items from subfolder of archive.
    outDir : output directory. If (testMode), outDir is ignored.
  */
  virtual void Extract(const uint32_t *indices, unsigned numIndices,
      const char *outDir, const char *prefix,
      EPathMode pathMode, EOverwriteMode overwriteMode,
      bool testMode,
      IUserCallback *callback, CResult &result) = 0;

  // returns password that was used to open archive or for extraction
  virtual const char *GetPassword() const = 0;
  // sets password for next Extract() calls
  virtual void SetPassword(const char *password) = 0;
};

/*
  OpenArchive() opens archive file.
  It returns NULL in case of error, and result.HResult is error code
  (S_FALSE (1) : the file is not archive).
  password can be NULL. If the archive requires password, callback->AskPassword() is called.
*/
IArchive *OpenArchive(const char *path, const char *password, IUserCallback *callback, CResult &result);

}

#endif
