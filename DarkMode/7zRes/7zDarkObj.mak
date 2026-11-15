# Modified 2026-11-15: keep the standard toolbar resources.


!IFDEF WIN_CTRL_OBJS
CFLAGS = $(CFLAGS) -GL -Gw -std:c++20 -Zc:enumTypes
LFLAGS = $(LFLAGS) /LTCG /DEPENDENTLOADFLAG:0x800 /BREPRO

DARK_MODE_OBJS = \
  $O\Darkmodelib.obj \
  $O\DmlibColor.obj \
  $O\DmlibDpi.obj \
  $O\DmlibHook.obj \
  $O\DmlibIni.obj \
  $O\DmlibPaintHelper.obj \
  $O\DmlibSubclass.obj \
  $O\DmlibSubclassControl.obj \
  $O\DmlibSubclassWindow.obj \
  $O\DmlibWinApi.obj \
!ENDIF

OBJS = \
  $(OBJS) \
  $(DARK_MODE_OBJS) \
