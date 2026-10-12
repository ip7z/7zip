// SZCommands.mm

#import "SZCommands.h"

#include <vector>
#import "SZCompressController.h"
#import "SZLang.h"
#import "SZLangIDs.h"
#import "SZProgressController.h"
#import "SZUtils.h"

using namespace NMacEngine;

void SZRunCommand(NSArray<NSString *> *args, NSString *title, NSString *subtitle,
    NSWindow *parent, SZCommandCompletion completion)
{
  SZOperation *op = [[SZOperation alloc] initWithTitle:title];
  op.subtitle = subtitle;
  NSArray *argsCopy = [args copy];
  [SZProgressController runOperation:op parent:parent work:^(SZOperation *o) {
    std::vector<const char *> v;
    for (NSString *s in argsCopy)
      v.push_back(s.UTF8String);
    CResult r;
    RunCommand(v.data(), (unsigned)v.size(), o.callback, r);
    o.result = r;
  } completion:^(SZOperation *o) {
    const CResult r = o.result;
    if (completion)
      completion(r.HResult == 0 && ![o hasErrors] && !o.cancelled);
  }];
}

void SZCompressFiles(NSArray<NSString *> *files, NSWindow *parent, SZCommandCompletion completion)
{
  if (files.count == 0)
    return;
  NSString *format = [[NSUserDefaults standardUserDefaults] stringForKey:@"Compress.Format"] ?: @"7z";
  NSString *ext = [format isEqualToString:@"gzip"] ? @"gz" : [format isEqualToString:@"bzip2"] ? @"bz2" : format;
  NSString *path = [SZCompressController defaultArchivePathForFiles:files extension:ext];
  [SZCompressController showForFiles:files archivePath:path parent:parent completion:^(SZCompressRequest *req) {
    if (!req)
    {
      if (completion)
        completion(NO);
      return;
    }
    SZRunCommand(req.args, SZLang(kLang_Compressing, @"Compressing"), req.archivePath.lastPathComponent, parent, completion);
  }];
}

void SZCompressFilesQuick(NSArray<NSString *> *files, NSString *format, NSWindow *parent, SZCommandCompletion completion)
{
  if (files.count == 0)
    return;
  NSString *path = [SZCompressController defaultArchivePathForFiles:files extension:format];
  NSArray *args = [SZCompressController quickArgsForFiles:files archivePath:path format:format];
  SZRunCommand(args, SZLang(kLang_Compressing, @"Compressing"), path.lastPathComponent, parent, completion);
}

NSArray<NSString *> *SZExtractSwitches(SZExtractOptions *o)
{
  NSMutableArray *a = [NSMutableArray array];
  switch (o.overwriteMode)
  {
    case kOverwriteMode_Overwrite:      [a addObject:@"-aoa"]; break;
    case kOverwriteMode_Skip:           [a addObject:@"-aos"]; break;
    case kOverwriteMode_Rename:         [a addObject:@"-aou"]; break;
    case kOverwriteMode_RenameExisting: [a addObject:@"-aot"]; break;
    default: break;
  }
  if (o.pathMode == kPathMode_Abs)
    [a addObject:@"-spf"];
  if (o.elimDup)
    [a addObject:@"-spe"];
  if (o.password.length)
    [a addObject:[@"-p" stringByAppendingString:o.password]];
  return a;
}

static NSString *ArchiveBaseName(NSString *path)
{
  NSString *name = path.lastPathComponent;
  // "name.tar.gz" -> "name.tar" -> "name" is not required: 7-Zip opens tar inside gz as one archive
  NSString *base = [name stringByDeletingPathExtension];
  // multivolume: "name.7z.001" -> "name"
  if ([[name pathExtension] rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound)
    base = [base stringByDeletingPathExtension];
  return base.length ? base : name;
}

static void RunExtract(NSArray<NSString *> *archives, SZExtractOptions *o, NSWindow *parent, SZCommandCompletion completion)
{
  NSMutableArray *a = [NSMutableArray arrayWithObject:(o.pathMode == kPathMode_No ? @"e" : @"x")];
  NSString *outDir = o.outputDir;
  if (![outDir hasSuffix:@"/"])
    outDir = [outDir stringByAppendingString:@"/"];
  [a addObject:[@"-o" stringByAppendingString:outDir]];
  [a addObjectsFromArray:SZExtractSwitches(o)];
  [a addObject:@"-spd"];
  [a addObject:@"-an"];
  for (NSString *arc in archives)
    [a addObject:[@"-ai!" stringByAppendingString:arc]];
  NSString *subtitle = archives.count == 1 ? archives[0].lastPathComponent :
      [NSString stringWithFormat:@"%lu %@", (unsigned long)archives.count, SZStripAmp(SZLang(kLang_Archives, @"Archives:"))];
  SZRunCommand(a, SZLang(kLang_Extracting, @"Extracting"), subtitle, parent, completion);
}

void SZExtractArchives(NSArray<NSString *> *archives, SZExtractMode mode, NSWindow *parent, SZCommandCompletion completion)
{
  if (archives.count == 0)
    return;
  NSString *dir = [archives[0] stringByDeletingLastPathComponent];
  NSString *sub = archives.count == 1 ? ArchiveBaseName(archives[0]) : @"*";

  if (mode == SZExtractModeHere || mode == SZExtractModeToFolder)
  {
    SZExtractOptions *o = [[SZExtractOptions alloc] init];
    o.baseDir = dir;
    o.outputDir = (mode == SZExtractModeHere) ? dir : [dir stringByAppendingPathComponent:@"*"];
    o.pathMode = kPathMode_Full;
    o.overwriteMode = kOverwriteMode_Ask;
    o.elimDup = (mode == SZExtractModeToFolder);
    RunExtract(archives, o, parent, completion);
    return;
  }

  [SZExtractController showWithDirectory:dir subfolder:sub showElimDup:YES parent:parent completion:^(SZExtractOptions *o) {
    if (!o)
    {
      if (completion)
        completion(NO);
      return;
    }
    RunExtract(archives, o, parent, completion);
  }];
}

void SZShowTestResult(SZOperation *op, NSWindow *parent)
{
  const CResult r = op.result;
  if (r.HResult != 0 || [op hasErrors] || op.cancelled)
    return;
  NSString *info = [NSString stringWithFormat:@"%@\n\n%@ %llu\n%@ %@",
      op.subtitle,
      SZStripAmp(SZLang(kLang_ProgressFiles, @"Files:")), r.NumFiles,
      SZStripAmp(SZLang(kLang_PropSize, @"Size")), SZFormatSize(r.UnpackSize)];
  if (r.UnpackSize == 0)
    info = [NSString stringWithFormat:@"%@\n\n%@ %llu", op.subtitle, SZStripAmp(SZLang(kLang_ProgressFiles, @"Files:")), r.NumFiles];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = SZLang(kLang_NoErrors, @"There are no errors");
  alert.informativeText = info;
  alert.icon = SZSymbol(@"checkmark.seal.fill", 48);
  if (parent && parent.isVisible && !parent.attachedSheet)
    [alert beginSheetModalForWindow:parent completionHandler:nil];
  else
    [alert runModal];
}

void SZTestArchives(NSArray<NSString *> *archives, NSWindow *parent, SZCommandCompletion completion)
{
  if (archives.count == 0)
    return;
  NSMutableArray *a = [NSMutableArray arrayWithObjects:@"t", @"-spd", @"-an", nil];
  for (NSString *arc in archives)
    [a addObject:[@"-ai!" stringByAppendingString:arc]];
  NSString *subtitle = archives.count == 1 ? archives[0].lastPathComponent :
      [NSString stringWithFormat:@"%lu %@", (unsigned long)archives.count, SZStripAmp(SZLang(kLang_Archives, @"Archives:"))];

  SZOperation *op = [[SZOperation alloc] initWithTitle:SZLang(kLang_Testing, @"Testing")];
  op.subtitle = subtitle;
  [SZProgressController runOperation:op parent:parent work:^(SZOperation *o) {
    std::vector<const char *> v;
    for (NSString *s in a)
      v.push_back(s.UTF8String);
    CResult r;
    RunCommand(v.data(), (unsigned)v.size(), o.callback, r);
    o.result = r;
  } completion:^(SZOperation *o) {
    SZShowTestResult(o, parent);
    if (completion)
      completion(o.result.HResult == 0 && ![o hasErrors]);
  }];
}
