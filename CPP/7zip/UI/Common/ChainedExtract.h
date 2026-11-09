// ChainedExtract.h

#ifndef ZIP7_INC_CHAINED_EXTRACT_H
#define ZIP7_INC_CHAINED_EXTRACT_H

#include "Extract.h"

HRESULT TryChainedExtract(
    CCodecs *codecs,
    const CArchiveLink &arcLink,
    UInt64 packSize,
    UInt64 completedBeforeArc,
    bool multi,
    const NWildcard::CCensorNode &wildcardCensor,
    const CExtractOptions &options,
    bool calcCrc,
    IExtractCallbackUI *callback,
    IFolderArchiveExtractCallback *callbackFAE,
    CArchiveExtractCallback *ecs,
    UString &errorMessage);

#endif
