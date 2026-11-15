// Modified 2026-11-15: optional appearance and archive drop settings.
// RegistryUtils.h

#ifndef ZIP7_INC_REGISTRY_UTILS_H
#define ZIP7_INC_REGISTRY_UTILS_H

#include "../../../Common/MyTypes.h"
#include "../../../Common/MyWindows.h"
#include "../../../Common/MyString.h"

void SaveRegLang(const UString &path);
void ReadRegLang(UString &path);

void SaveRegEditor(bool useEditor, const UString &path);
void ReadRegEditor(bool useEditor, UString &path);

void SaveRegDiff(const UString &path);
void ReadRegDiff(UString &path);

void ReadReg_VerCtrlPath(UString &path);

struct CFmSettings
{
  bool ShowDots;
  bool ShowRealFileIcons;
  bool FullRow;
  bool ShowGrid;
  bool SingleClick;
  bool AlternativeSelection;
  // bool Underline;

  bool ShowSystemMenu;
  bool Open7zOnDrop;

  void Save() const;
  void Load();
};

// void SaveLockMemoryAdd(bool enable);
// bool ReadLockMemoryAdd();

bool ReadLockMemoryEnable();
void SaveLockMemoryEnable(bool enable);

void SaveFlatView(UInt32 panelIndex, bool enable);
bool ReadFlatView(UInt32 panelIndex);

/*
void Save_ShowDeleted(bool enable);
bool Read_ShowDeleted();
*/

void Save_ClrMode(UInt32 clrMode);
UInt32 Read_ClrMode();
void Apply_ClrMode(bool resetColors);
void Set_ClrModeWindow(HWND window);

#endif
