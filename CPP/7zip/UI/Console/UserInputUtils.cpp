// UserInputUtils.cpp

#include "StdAfx.h"

#include "../../../Common/StdInStream.h"
#include "../../../Common/StringConvert.h"

#include "UserInputUtils.h"

static const char kYes = 'y';
static const char kNo = 'n';
static const char kYesAll = 'a';
static const char kNoAll = 's';
static const char kAutoRenameAll = 'u';
static const char kQuit = 'q';

static const char * const kFirstQuestionMessage = "? ";
static const char * const kHelpQuestionMessage =
  "(Y)es / (N)o / (A)lways / (S)kip all / A(u)to rename all / (Q)uit? ";

// return true if pressed Quite;

NUserAnswerMode::EEnum ScanUserYesNoAllQuit(CStdOutStream *outStream)
{
  if (outStream)
    *outStream << kFirstQuestionMessage;
  for (;;)
  {
    if (outStream)
    {
      *outStream << kHelpQuestionMessage;
      outStream->Flush();
    }
    AString scannedString;
    if (!g_StdIn.ScanAStringUntilNewLine(scannedString))
      return NUserAnswerMode::kError;
    if (g_StdIn.Error())
      return NUserAnswerMode::kError;
    scannedString.Trim();
    if (scannedString.IsEmpty() && g_StdIn.Eof())
      return NUserAnswerMode::kEof;

    if (scannedString.Len() == 1)
      switch (::MyCharLower_Ascii(scannedString[0]))
      {
        case kYes:    return NUserAnswerMode::kYes;
        case kNo:     return NUserAnswerMode::kNo;
        case kYesAll: return NUserAnswerMode::kYesAll;
        case kNoAll:  return NUserAnswerMode::kNoAll;
        case kAutoRenameAll: return NUserAnswerMode::kAutoRenameAll;
        case kQuit:   return NUserAnswerMode::kQuit;
        default: break;
      }
  }
}

#ifdef _WIN32
#ifndef UNDER_CE
#define MY_DISABLE_ECHO
#define MY_DISABLE_ECHO_WIN32
#endif
#endif

#ifdef unix
#include <stdio.h>
#include <termios.h>
#include <unistd.h>
#define MY_DISABLE_ECHO
#define MY_DISABLE_ECHO_UNIX
#endif

static bool GetPassword(CStdOutStream *outStream, UString &psw)
{
  if (outStream)
  {
    *outStream << "\nEnter password"
      #ifdef MY_DISABLE_ECHO
      " (will not be echoed)"
      #endif
      ":";
    outStream->Flush();
  }

  #ifdef MY_DISABLE_ECHO_WIN32
  
  const HANDLE console = GetStdHandle(STD_INPUT_HANDLE);

  /*
  GetStdHandle() returns
    INVALID_HANDLE_VALUE: If the function fails.
    NULL : If an application does not have associated standard handles,
           such as a service running on an interactive desktop,
           and has not redirected them. */
  bool wasChanged = false;
  DWORD mode = 0;
  if (console != INVALID_HANDLE_VALUE && console != NULL)
    if (GetConsoleMode(console, &mode))
      wasChanged = (SetConsoleMode(console, mode & ~(DWORD)ENABLE_ECHO_INPUT) != 0);
  const bool res = g_StdIn.ScanUStringUntilNewLine(psw);
  if (wasChanged)
    SetConsoleMode(console, mode);

  #elif defined(MY_DISABLE_ECHO_UNIX)

  int ifd = fileno(stdin);
  bool wasChanged = false;
  struct termios old_mode = {};
  struct termios new_mode = {};

  if (tcgetattr(ifd, &old_mode) == 0) {
    new_mode = old_mode;
    new_mode.c_lflag &= ~ECHO;

    wasChanged = true;

    tcsetattr(ifd, TCSAFLUSH, &new_mode);
  }

  bool res = g_StdIn.ScanUStringUntilNewLine(psw);

  if (wasChanged) {
    tcsetattr(ifd, TCSAFLUSH, &old_mode);
  }
    
  #else
  
  const bool res = g_StdIn.ScanUStringUntilNewLine(psw);
  
  #endif

  if (outStream)
  {
    *outStream << endl;
    outStream->Flush();
  }

  return res;
}

HRESULT GetPassword_HRESULT(CStdOutStream *outStream, UString &psw)
{
  if (!GetPassword(outStream, psw))
    return E_INVALIDARG;
  if (g_StdIn.Error())
    return E_FAIL;
  if (g_StdIn.Eof() && psw.IsEmpty())
    return E_ABORT;
  return S_OK;
}
