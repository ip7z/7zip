// UserInputUtils.cpp

#include "StdAfx.h"

#include "../../../Common/StdInStream.h"
#include "../../../Common/StringConvert.h"

#include "UserInputUtils.h"

#include <iostream>
#ifdef _WIN32
#include <windows.h>
#elif defined(__linux__)
#include <termios.h>
#include <unistd.h>
#endif

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
#endif
#endif

static bool GetPassword(CStdOutStream *outStream, UString &psw)
{
  if (outStream)
  {
    *outStream << "\nEnter password (will not be echoed):";
    outStream->Flush();
  }

#ifdef _WIN32
  // Windows: disable echo
  const HANDLE console = GetStdHandle(STD_INPUT_HANDLE);
  DWORD mode = 0;
  bool wasChanged = false;
  if (console != INVALID_HANDLE_VALUE && console != NULL)
    if (GetConsoleMode(console, &mode))
      wasChanged = (SetConsoleMode(console, mode & ~(DWORD)ENABLE_ECHO_INPUT) != 0);

  const bool res = g_StdIn.ScanUStringUntilNewLine(psw);

  if (wasChanged)
    SetConsoleMode(console, mode);

#elif defined(__linux__)
  // Linux: disable echo using termios
  termios oldt;
  if (tcgetattr(STDIN_FILENO, &oldt) != 0)
    return false;

  termios newt = oldt;
  newt.c_lflag &= ~ECHO;
  if (tcsetattr(STDIN_FILENO, TCSANOW, &newt) != 0)
    return false;

  const bool res = g_StdIn.ScanUStringUntilNewLine(psw);

  tcsetattr(STDIN_FILENO, TCSANOW, &oldt);

#else
  // Fallback: no echo masking
  const bool res = g_StdIn.ScanUStringUntilNewLine(psw);
#endif

  if (outStream)
  {
    *outStream << '\n';
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
