#include <algorithm>
#include <cassert>
#include <cstdio>
#include <vector>
#include "../CPP/Common/MyInitGuid.h"
#include "../CPP/7zip/Common/FilterCoder.h"
#include "../CPP/7zip/Compress/TransposeFilter.cpp"

void RegisterCodec(const CCodecInfo *) throw() {}
using namespace NCompress::NTranspose;

class Input final: public ISequentialInStream, public CMyUnknownImp {
public:
  std::vector<Byte> data;
  size_t pos;
  UInt32 chunk;
  Input(const std::vector<Byte>& d, UInt32 c): data(d), pos(0), chunk(c) {}
  Z7_IFACES_IMP_UNK_1(ISequentialInStream)
};
Z7_COM7F_IMF(Input::Read(void *buf, UInt32 size, UInt32 *done)) {
  size = (UInt32)std::min<size_t>(std::min(size, chunk), data.size() - pos);
  if (size) memcpy(buf, data.data() + pos, size);
  pos += size; *done = size; return S_OK;
}
class Output final: public ISequentialOutStream, public CMyUnknownImp {
public:
  std::vector<Byte> data;
  Z7_IFACES_IMP_UNK_1(ISequentialOutStream)
};
Z7_COM7F_IMF(Output::Write(const void *buf, UInt32 size, UInt32 *done)) {
  size = std::min<UInt32>(size, 131);
  const Byte *p = (const Byte *)buf;
  data.insert(data.end(), p, p + size);
  if (done) *done = size;
  return S_OK;
}

static std::vector<Byte> Run(const std::vector<Byte>& data, unsigned R,
    unsigned exp, bool encode, unsigned path, UInt32 buffer) {
  CFilterCoder coder(encode);
  if (encode) {
    CEncoder *enc = new CEncoder;
    coder.Filter = enc;
    PROPID id = NCoderPropID::kDefaultProp;
    PROPVARIANT value = {}; value.vt = VT_UI4; value.ulVal = R;
    assert(static_cast<ICompressSetCoderProperties *>(enc)->SetCoderProperties(&id, &value, 1) == S_OK);
    // PickExp(size) == exp.
    id = NCoderPropID::kExpectedDataSize;
    value.vt = VT_UI8; value.uhVal.QuadPart = (UInt64)32 << exp;
    assert(static_cast<ICompressSetCoderPropertiesOpt *>(enc)->SetCoderPropertiesOpt(&id, &value, 1) == S_OK);
  } else {
    CDecoder *dec = new CDecoder;
    coder.Filter = dec;
    const Byte props[] = {(Byte)(R - 1), (Byte)Transpose_StepExp(R, exp)};
    assert(static_cast<ICompressSetDecoderProperties2 *>(dec)->SetDecoderProperties2(props, 2) == S_OK);
  }
  assert(static_cast<ICompressSetBufSize *>(&coder)->SetInBufSize(0, buffer) == S_OK);
  assert(static_cast<ICompressSetBufSize *>(&coder)->SetOutBufSize(0, buffer + 123) == S_OK);
  Input *in = new Input(data, 137);
  CMyComPtr<ISequentialInStream> ip = in;
  Output *out = new Output;
  CMyComPtr<ISequentialOutStream> op = out;
  if (path == 0) {
    assert(static_cast<ICompressCoder *>(&coder)->Code(ip, op, NULL, NULL, NULL) == S_OK);
  } else if (path == 1) {
    assert(static_cast<ICompressSetInStream *>(&coder)->SetInStream(ip) == S_OK);
    assert(static_cast<ICompressSetOutStreamSize *>(&coder)->SetOutStreamSize(NULL) == S_OK);
    Byte b[193];
    for (;;) {
      UInt32 n;
      assert(static_cast<ISequentialInStream *>(&coder)->Read(b, sizeof(b), &n) == S_OK);
      if (!n) break;
      out->data.insert(out->data.end(), b, b + n);
    }
  } else {
    assert(static_cast<ICompressSetOutStream *>(&coder)->SetOutStream(op) == S_OK);
    assert(static_cast<ICompressSetOutStreamSize *>(&coder)->SetOutStreamSize(NULL) == S_OK);
    size_t pos = 0;
    while (pos < data.size()) {
      UInt32 n;
      assert(static_cast<ISequentialOutStream *>(&coder)->Write(data.data() + pos, (UInt32)std::min<size_t>(997, data.size() - pos), &n) == S_OK);
      assert(n > 0); pos += n;
    }
    assert(static_cast<IOutStreamFinish *>(&coder)->OutStreamFinish() == S_OK);
  }
  if (encode) {
    Output *props = new Output;
    CMyComPtr<ISequentialOutStream> pp = props;
    CMyComPtr<ICompressWriteCoderProperties> wp;
    assert(coder.Filter.QueryInterface(IID_ICompressWriteCoderProperties, &wp) == S_OK);
    assert(wp->WriteCoderProperties(pp) == S_OK);
    assert(props->data.size() == 2 && props->data[0] == R-1);
  }
  return out->data;
}
int main() {
  unsigned count = 0;
  for (unsigned R = 1; R <= 256; ++R) {
    for (unsigned exp: {12u, 16u}) {
      const size_t rows = (size_t)1 << Transpose_StepExp(R, exp);
      const size_t block = rows * R;
      for (size_t n: {size_t(0), size_t(1), block-1, block, block+1, size_t(65535), size_t(65536), size_t(131073)}) {
        std::vector<Byte> d(n), ref;
        unsigned x = 4124;
        for (Byte &b: d) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b = (Byte)x; }
        ref = d;
        for (size_t off = 0; off + block <= n; off += block)
          for (size_t c = 0; c < R; ++c)
            for (size_t i = 0; i < rows; ++i)
              ref[off + c * rows + i] = d[off + i * R + c];
        for (unsigned path = 0; path < 3; ++path) {
          const UInt32 bs = path == 0 ? 4096 : path == 1 ? 65536 : 131072;
          auto enc = Run(d, R, exp, true, path, bs);
          assert(enc == ref);
          assert(Run(enc, R, exp, false, (path + 1) % 3, 4096) == d);
          ++count;
        }
      }
    }
  }
  CDecoder dec;
  Byte props[3] = {255, 16, 0};
  for (unsigned len: {0u, 1u, 3u}) assert(static_cast<ICompressSetDecoderProperties2 *>(&dec)->SetDecoderProperties2(props, len) == E_INVALIDARG);
  assert(static_cast<ICompressSetDecoderProperties2 *>(&dec)->SetDecoderProperties2(props, 2) == E_INVALIDARG);
  props[0] = 0; props[1] = 17;
  assert(static_cast<ICompressSetDecoderProperties2 *>(&dec)->SetDecoderProperties2(props, 2) == E_INVALIDARG);
  printf("%u stream round trips + independent reference + invalid properties passed\n", count);
}
