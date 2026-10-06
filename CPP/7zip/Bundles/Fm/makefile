PROG = 7zFM.exe
UI_FILEMANAGER_PROGPATH = ..\..\UI\FileManager\$(O)\$(PROG)
REPO_LANG_DIR = ..\..\..\..\Lang
FM_LANG_DIR = $(O)\Lang
UI_FILEMANAGER_LANG_DIR = ..\..\UI\FileManager\$(O)\Lang

!include "../Format7zF/Arc.mak"

!include "../../UI/FileManager/FM.mak"

COMMON_OBJS = $(COMMON_OBJS) \
  $O\CommandLineParser.obj \
  $O\Lang.obj \
  $O\ListFileUtils.obj \
  $O\Random.obj \

WIN_OBJS = $(WIN_OBJS) \
  $O\Clipboard.obj \
  $O\CommonDialog.obj \
  $O\DLL.obj \
  $O\ErrorMsg.obj \
  $O\FileLink.obj \
  $O\MemoryGlobal.obj \
  $O\MemoryLock.obj \
  $O\Menu.obj \
  $O\ProcessUtils.obj \
  $O\Registry.obj \
  $O\ResourceString.obj \
  $O\SystemInfo.obj \
  $O\Shell.obj \
  $O\Window.obj \

WIN_CTRL_OBJS = \
  $O\ComboBox.obj \
  $O\Dialog.obj \
  $O\ListView.obj \
  $O\PropertyPage.obj \
  $O\Window2.obj \

7ZIP_COMMON_OBJS = $(7ZIP_COMMON_OBJS) \
  $O\FilePathAutoRename.obj \
  $O\FileStreams.obj \
  $O\MultiOutStream.obj \

UI_COMMON_OBJS = \
  $O\ArchiveExtractCallback.obj \
  $O\ArchiveName.obj \
  $O\ArchiveOpenCallback.obj \
  $O\Bench.obj \
  $O\CompressCall2.obj \
  $O\DefaultName.obj \
  $O\EnumDirItems.obj \
  $O\Extract.obj \
  $O\ExtractingFilePath.obj \
  $O\HashCalc.obj \
  $O\LoadCodecs.obj \
  $O\OpenArchive.obj \
  $O\PropIDUtils.obj \
  $O\SetProperties.obj \
  $O\SortUtils.obj \
  $O\TempFiles.obj \
  $O\Update.obj \
  $O\UpdateAction.obj \
  $O\UpdateCallback.obj \
  $O\UpdatePair.obj \
  $O\UpdateProduce.obj \
  $O\WorkDir.obj \
  $O\ZipRegistry.obj \

EXPLORER_OBJS = \
  $O\ContextMenu.obj \
  $O\MyMessages.obj \
  $O\RegistryContextMenu.obj \

GUI_OBJS = \
  $O\BenchmarkDialog.obj \
  $O\CompressDialog.obj \
  $O\ExtractDialog.obj \
  $O\ExtractGUI.obj \
  $O\HashGUI.obj \
  $O\UpdateCallbackGUI.obj \
  $O\UpdateCallbackGUI2.obj \
  $O\UpdateGUI.obj \


!include "../../7zip.mak"

all: copy_lang $(UI_FILEMANAGER_PROGPATH)

copy_lang:
	if not exist "$(FM_LANG_DIR)" mkdir "$(FM_LANG_DIR)"
	copy /Y "$(REPO_LANG_DIR)\*" "$(FM_LANG_DIR)\" >nul
	if not exist "$(UI_FILEMANAGER_LANG_DIR)" mkdir "$(UI_FILEMANAGER_LANG_DIR)"
	copy /Y "$(REPO_LANG_DIR)\*" "$(UI_FILEMANAGER_LANG_DIR)\" >nul

$(UI_FILEMANAGER_PROGPATH): $(PROGPATH)
	if not exist "..\..\UI\FileManager\$(O)" mkdir "..\..\UI\FileManager\$(O)"
	copy /Y "$(PROGPATH)" "$(UI_FILEMANAGER_PROGPATH)" >nul

$O\CompressDialog.obj: ../../UI/GUI/CompressDialog.cpp ../../UI/GUI/CompressDialog.h ../../UI/GUI/CompressDialogRes.h
$O\CompressCall2.obj: ../../UI/Common/CompressCall2.cpp ../../UI/Common/Update.h ../../UI/GUI/UpdateGUI.h
$O\Update.obj: ../../UI/Common/Update.cpp ../../UI/Common/Update.h
$O\UpdateCallbackGUI.obj: ../../UI/GUI/UpdateCallbackGUI.cpp ../../UI/Common/Update.h ../../UI/GUI/UpdateCallbackGUI.h
$O\UpdateGUI.obj: ../../UI/GUI/UpdateGUI.cpp ../../UI/Common/Update.h ../../UI/GUI/UpdateGUI.h ../../UI/GUI/CompressDialog.h ../../UI/GUI/CompressDialogRes.h
$O\resource.res: resource.rc ../../UI/GUI/resource2.rc ../../UI/GUI/CompressDialog.rc ../../UI/GUI/CompressDialogRes.h ../../UI/FileManager/AboutDialog.rc ../../UI/FileManager/AboutDialogRes.h
