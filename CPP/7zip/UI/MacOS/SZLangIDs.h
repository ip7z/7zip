// SZLangIDs.h

/*
  String IDs for lang files.
  These values are the same as in Windows version of 7-Zip:
    FileManager/resource.h, GUI/xxxRes.h, FileManager/xxxRes.h
  Do not change them. New strings that don't exist in Windows version
  are shown in English only (ID = 0).
*/

#ifndef ZIP7_INC_SZ_LANG_IDS_H
#define ZIP7_INC_SZ_LANG_IDS_H

enum
{
  kLang_None = 0,

  // menus (FileManager/resource.h)
  kLang_MenuFile = 500,
  kLang_MenuEdit = 501,
  kLang_MenuView = 502,
  kLang_MenuFavorites = 503,
  kLang_MenuTools = 504,
  kLang_MenuHelp = 505,
  kLang_Open = 540,
  kLang_OpenInside = 541,
  kLang_OpenOutside = 542,
  kLang_Rename = 545,
  kLang_CopyTo = 546,
  kLang_MoveTo = 547,
  kLang_Delete = 548,
  kLang_Properties = 551,
  kLang_CreateFolder = 555,
  kLang_SelectAll = 600,
  kLang_DeselectAll = 601,
  kLang_InvertSelection = 602,
  kLang_OpenRootFolder = 734,
  kLang_OpenParentFolder = 735,
  kLang_Refresh = 737,
  kLang_Options = 900,
  kLang_Benchmark = 901,
  kLang_HelpContents = 960,
  kLang_About = 961,

  // buttons
  kLang_OK = 401,
  kLang_Cancel = 402,
  kLang_Close = 408,
  kLang_Continue = 411,
  kLang_YesToAll = 440,
  kLang_NoToAll = 441,
  kLang_Background = 444,
  kLang_Foreground = 445,
  kLang_Pause = 446,
  kLang_Paused = 447,
  kLang_AskCancel = 448,

  // context menu (Explorer/resource.h)
  kLang_CtxOpen = 2322,
  kLang_CtxExtract = 2323,
  kLang_CtxCompress = 2324,
  kLang_CtxTest = 2325,
  kLang_CtxExtractHere = 2326,
  kLang_CtxExtractTo = 2327,
  kLang_CtxCompressTo = 2328,

  // property names (FileManager/PropertyNameRes.h) : 1000 + kpid
  kLang_PropName = 1004,
  kLang_PropSize = 1007,
  kLang_PropPackedSize = 1008,
  kLang_PropAttributes = 1009,
  kLang_PropCTime = 1010,
  kLang_PropMTime = 1012,
  kLang_PropEncrypted = 1015,
  kLang_PropCRC = 1019,
  kLang_PropType = 1020,
  kLang_PropMethod = 1022,
  kLang_PropFolders = 1031,
  kLang_PropFiles = 1032,

  // about
  kLang_AboutInfo = 2901,
  kLang_Homepage = 110,

  // messages
  kLang_NoErrors = 3001,
  kLang_NSelectedItems = 3002,
  kLang_UpdateNotSupported = 3004,
  kLang_CantOpenArchive = 3005,
  kLang_FileExists = 3008,
  kLang_SelectOneFile = 3014,
  kLang_SelectFiles = 3015,

  // progress
  kLang_Extracting = 3300,
  kLang_Compressing = 3301,
  kLang_Testing = 3302,
  kLang_Opening = 3303,
  kLang_Scanning = 3304,
  kLang_Removing = 3305,
  kLang_OpAdd = 3320,
  kLang_OpUpdate = 3321,
  kLang_OpAnalyze = 3322,
  kLang_OpReplicate = 3323,
  kLang_OpRepack = 3324,
  kLang_OpSkipping = 3325,
  kLang_OpDelete = 3326,
  kLang_OpHeader = 3327,
  kLang_ProgressPacked = 1008,
  kLang_ProgressFiles = 1032,
  kLang_ProgressElapsed = 3900,
  kLang_ProgressRemaining = 3901,
  kLang_ProgressTotal = 3902,
  kLang_ProgressSpeed = 3903,
  kLang_ProgressProcessed = 3904,
  kLang_ProgressRatio = 3905,
  kLang_ProgressErrors = 3906,
  kLang_Archives = 3907,
  kLang_Moving = 6005,

  // extract dialog (GUI/ExtractDialogRes.h, GUI/ExtractRes.h)
  kLang_ExtractTitle = 3400,
  kLang_ExtractTo = 3401,
  kLang_ExtractSetFolder = 3402,
  kLang_PathMode = 3410,
  kLang_PathsFull = 3411,
  kLang_PathsNo = 3412,
  kLang_PathsAbs = 3413,
  kLang_PathsRelative = 3414,
  kLang_OverwriteMode = 3420,
  kLang_OverwriteAsk = 3421,
  kLang_OverwriteWithoutPrompt = 3422,
  kLang_OverwriteSkip = 3423,
  kLang_OverwriteRename = 3424,
  kLang_OverwriteRenameExisting = 3425,
  kLang_ElimDup = 3430,

  // overwrite dialog (FileManager/OverwriteDialogRes.h)
  kLang_OverwriteHeader = 3500, // title
  kLang_OverwriteDestContains = 3501,
  kLang_OverwriteQuestionBegin = 3502,
  kLang_OverwriteQuestionEnd = 3503,
  kLang_AutoRename = 3505,

  // password
  kLang_PasswordTitle = 3800,
  kLang_PasswordEnter = 3801,
  kLang_PasswordReenter = 3802,
  kLang_PasswordShow = 3803,
  kLang_PasswordNotMatch = 3804,
  kLang_PasswordUseAscii = 3805,
  kLang_PasswordTooLong = 3806,
  kLang_PasswordGroup = 3807,

  // compress dialog (GUI/CompressDialogRes.h)
  kLang_AddToArchive = 4000, // title
  kLang_CompressArchive = 4001,
  kLang_CompressUpdateMode = 4002,
  kLang_CompressFormat = 4003,
  kLang_CompressLevel = 4004,
  kLang_CompressMethod = 4005,
  kLang_CompressDictionary = 4006,
  kLang_CompressOrder = 4007,
  kLang_CompressSolid = 4008,
  kLang_CompressThreads = 4009,
  kLang_CompressParameters = 4010,
  kLang_CompressOptionsGroup = 4011,
  kLang_CompressEncryption = 4014,
  kLang_CompressEncryptionMethod = 4015,
  kLang_CompressEncryptFileNames = 4016,
  kLang_CompressMemory = 4017,
  kLang_CompressMemoryDe = 4018,
  kLang_CompressDeleteAfter = 4019,
  kLang_CompressNtSymLinks = 4040,
  kLang_MethodStore = 4050,
  kLang_MethodFastest = 4051,
  kLang_MethodFast = 4052,
  kLang_MethodNormal = 4053,
  kLang_MethodMaximum = 4054,
  kLang_MethodUltra = 4055,
  kLang_UpdateModeAdd = 4060,
  kLang_UpdateModeUpdate = 4061,
  kLang_UpdateModeFresh = 4062,
  kLang_UpdateModeSync = 4063,
  kLang_CompressBrowse = 4070,
  kLang_AllFiles = 4071,
  kLang_NonSolid = 4072,
  kLang_Solid = 4073,
  kLang_SplitToVolumes = 7302,
  kLang_IncorrectVolumeSize = 7307,

  // FM messages
  kLang_Copy = 6000,
  kLang_Move = 6001,
  kLang_ConfirmFileDelete = 6100,
  kLang_ConfirmFolderDelete = 6101,
  kLang_ConfirmItemsDelete = 6102,
  kLang_WantDeleteFile = 6103,
  kLang_WantDeleteFolder = 6104,
  kLang_WantDeleteItems = 6105,
  kLang_Deleting = 6106,
  kLang_CreateFolderTitle = 6300,
  kLang_CreateFolderName = 6302,
  kLang_CreateFolderDefault = 6304,
  kLang_PropertiesTitle = 6600,
  kLang_Computer = 7100,
  kLang_Documents = 7102,

  // toolbar (FileManager/resource.h)
  kLang_Add = 7200,
  kLang_Extract = 7201,
  kLang_Test = 7202,
  kLang_ButtonCopy = 7203,
  kLang_ButtonMove = 7204,
  kLang_ButtonDelete = 7205,
  kLang_ButtonInfo = 7206
};

#endif
