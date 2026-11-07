// SZLang.mm

#import "SZLang.h"

#include "MacEngine.h"

NSString * const SZLangDefaultsKey = @"Language";

static NSString *g_LangCode;

static NSString *LangDir(void)
{
  return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Lang"];
}

NSArray<NSString *> *SZLangAvailableCodes(void)
{
  NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:LangDir() error:nil];
  NSMutableArray *codes = [NSMutableArray array];
  for (NSString *f in files)
    if ([[f pathExtension] isEqualToString:@"txt"])
      [codes addObject:[f stringByDeletingPathExtension]];
  [codes sortUsingSelector:@selector(compare:)];
  return codes;
}

// converts macOS language identifier ("pt-BR", "zh-Hans-CN") to 7-Zip lang file names
static NSArray<NSString *> *CandidatesForLanguage(NSString *lang)
{
  NSString *l = [lang lowercaseString];
  NSMutableArray *res = [NSMutableArray array];
  if ([l hasPrefix:@"zh-hans"])
    [res addObject:@"zh-cn"];
  else if ([l hasPrefix:@"zh-hant"])
    [res addObject:@"zh-tw"];
  [res addObject:l];
  NSArray *parts = [l componentsSeparatedByString:@"-"];
  if (parts.count > 2)
    [res addObject:[NSString stringWithFormat:@"%@-%@", parts[0], parts.lastObject]];
  if (parts.count > 1)
    [res addObject:parts[0]];
  return res;
}

static NSString *FindLangCode(void)
{
  NSArray<NSString *> *available = SZLangAvailableCodes();
  if (available.count == 0)
    return nil;
  NSString *forced = [[NSUserDefaults standardUserDefaults] stringForKey:SZLangDefaultsKey];
  if (forced.length != 0)
  {
    if ([forced isEqualToString:@"-"] || ![available containsObject:forced])
      return nil;
    return forced;
  }
  for (NSString *lang in [NSLocale preferredLanguages])
  {
    if ([[lang lowercaseString] hasPrefix:@"en"])
      return nil;
    for (NSString *c in CandidatesForLanguage(lang))
      if ([available containsObject:c])
        return c;
  }
  return nil;
}

BOOL SZLangInit(void)
{
  g_LangCode = FindLangCode();
  NSString *path = nil;
  if (g_LangCode)
    path = [LangDir() stringByAppendingPathComponent:[g_LangCode stringByAppendingPathExtension:@"txt"]];
  return NMacEngine::Init(path ? path.fileSystemRepresentation : NULL);
}

NSString *SZLangCurrentCode(void)
{
  return g_LangCode;
}

NSString *SZLang(uint32_t langID, NSString *defaultString)
{
  const char *s = NMacEngine::LangString(langID, NULL);
  if (!s)
    return defaultString;
  NSString *r = [NSString stringWithUTF8String:s];
  return r.length ? r : defaultString;
}

NSString *SZLangFormat(uint32_t langID, NSString *defaultString, NSString *param)
{
  return [SZLang(langID, defaultString) stringByReplacingOccurrencesOfString:@"{0}" withString:param ? param : @""];
}
