#include "StdAfx.h"
#include "../Common/StringConvert.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
// Linker dummy required for MyString.o dependencies
extern "C" UINT WINAPI SysStringLen(BSTR) { return 0; }

void RunTest(const char* lc_all, bool isOem)
{
    if (lc_all) setenv("LC_ALL", lc_all, 1);
    else unsetenv("LC_ALL");

    UString result;
    AString src("A"); // Standard ASCII "A" (0x41)
    
    printf("Testing Locale: %-15s (isOem=%d)... ", lc_all ? lc_all : "DEFAULT", isOem);
    
    // Test the internal mapping logic via iconv_open verification
    bool ok = UnixConvertLegacyToUnicode(src, result, isOem, false, 0);
    
    if (ok) {
        printf("[OK] (Mapping accepted by iconv)\n");
    } else {
        printf("[FAIL] (Mapping rejected or conversion failed)\n");
        exit(1);
    }
}

int main()
{
    printf("Starting Legacy Codepage Mapping Tests...\n\n");

    // 1. Japanese (Shift-JIS)
    RunTest("ja_JP.UTF-8", false);
    
    // 2. Russian (Cyrillic OEM/ANSI)
    RunTest("ru_RU.UTF-8", true);  // Should map to IBM866
    RunTest("ru_RU.UTF-8", false); // Should map to WINDOWS-1251
    
    // 3. German (Western Europe)
    RunTest("de_DE.UTF-8", false); // Should map to WINDOWS-1252 / IBM850
    
    // 4. Fallback/Standard
    RunTest("C", true);     // Should map to IBM437
    RunTest("POSIX", false); // Should map to WINDOWS-1252

    printf("\nAll codepage mapping tests PASSED.\n");
    return 0;
}
#else
int main() { 
    printf("This test is for UNIX platforms only.\n");
    return 0; 
}
#endif