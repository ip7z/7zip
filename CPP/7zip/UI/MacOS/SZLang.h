// SZLang.h

/*
  Localization for 7-Zip GUI for macOS.

  It uses the same lang files (Lang/xx.txt) and the same string IDs
  as 7-Zip for Windows. So existing translations can be used.
  The IDs are same as in Windows resource files (resource.h, *Res.h).
*/

#import <Foundation/Foundation.h>

// SZLangInit() selects lang file and initializes the engine.
// returns NO, if the engine can't be initialized.
BOOL SZLangInit(void);

// returns translated string or (defaultString), if there is no translation.
NSString *SZLang(uint32_t langID, NSString *defaultString);

// returns translated string with "{0}" replaced by (param).
NSString *SZLangFormat(uint32_t langID, NSString *defaultString, NSString *param);

// the code of current lang file ("pt-br"), or nil for English.
NSString *SZLangCurrentCode(void);
NSArray<NSString *> *SZLangAvailableCodes(void);

// the key in NSUserDefaults to override the lang ("-" means English)
extern NSString * const SZLangDefaultsKey;
