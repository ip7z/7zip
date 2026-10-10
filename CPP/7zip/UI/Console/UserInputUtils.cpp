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
#endif
#endif

static void OutputPassInputMessage(CStdOutStream *outStream, const UString &msg)
{
  if (outStream)
  {
    *outStream << '\n' << msg
      #ifdef MY_DISABLE_ECHO
      << " (will not be echoed)"
      #endif
      << ":";
    outStream->Flush();
  }
}

static bool PassInput(UString &psw)
{
  bool res = false;

  #ifdef MY_DISABLE_ECHO

  /*
  GetStdHandle() returns
    INVALID_HANDLE_VALUE: If the function fails.
    NULL : If an application does not have associated standard handles,
           such as a service running on an interactive desktop,
           and has not redirected them. */
  const HANDLE console = GetStdHandle(STD_INPUT_HANDLE);
  DWORD mode = 0;
  bool wasChanged = false;

  if (console != INVALID_HANDLE_VALUE && console != NULL)
    if (GetConsoleMode(console, &mode))
      wasChanged = (SetConsoleMode(console, mode & ~(DWORD)ENABLE_ECHO_INPUT) != 0);
  res = g_StdIn.ScanUStringUntilNewLine(psw);
  if (wasChanged)
    SetConsoleMode(console, mode);

  # else

  res = g_StdIn.ScanUStringUntilNewLine(psw);

  #endif

  return res;
}

static void EndOutStream(CStdOutStream *outStream)
{
  if (outStream)
  {
    *outStream << endl;
    outStream->Flush();
  }
}

static bool GetPassword(CStdOutStream *outStream, UString &psw, const bool confirm)
{
  UString confirmPsw;
  UString passInMsg;
  bool res = false;

  passInMsg = "Enter password";
  OutputPassInputMessage(outStream, passInMsg);
  res = PassInput(psw);
  if (!res)
  {
    EndOutStream(outStream);
    return res;
  }

  if (confirm)
  {
    passInMsg = "Confirm password";
    OutputPassInputMessage(outStream, passInMsg);
    res = PassInput(confirmPsw);
    if (!res)
    {
      EndOutStream(outStream);
      return res;
    }

    if (psw != confirmPsw)
    {
      if (outStream)
      {
        *outStream << '\n'
	           << "Confirm password is different from "
                   << "the initially entered password, stopping. "
                   << "Try again!";
      }
      res = false;
    }
  }

  EndOutStream(outStream);
  return res;
}

static HRESULT HandleHRESULT(bool res, UString &psw)
{
  if (!res)
    return E_INVALIDARG;
  if (g_StdIn.Error())
    return E_FAIL;
  if (g_StdIn.Eof() && psw.IsEmpty())
    return E_ABORT;
  return S_OK;
}

HRESULT GetPasswordConfirm_HRESULT(CStdOutStream *outStream, UString &psw)
{
  return HandleHRESULT(GetPassword(outStream, psw, true), psw);
}

HRESULT GetPassword_HRESULT(CStdOutStream *outStream, UString &psw)
{
  return HandleHRESULT(GetPassword(outStream, psw, false), psw);
}
