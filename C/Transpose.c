/* Transpose.c -- Byte-transposition converter
   Domaine public. */

#include "Precomp.h"
#include <string.h>

#include "Transpose.h"
#include "LzmaEnc.h"
#include "Alloc.h"
#include "Ppmd7.h"

/* The wire format stores log2(records per block), not a byte-size exponent.
   Decoding only needs shifts and multiplication; there is no division. */
unsigned Transpose_StepExp(unsigned R, unsigned exp)
{
  unsigned step = 0;
  while (((SizeT)R << (step + 1)) <= ((SizeT)1 << exp))
    step++;
  return step;
}

unsigned Transpose_PickExp(UInt64 size)
{
  unsigned e = TRANSPOSE_EXP_MIN;
  while (e < TRANSPOSE_EXP_MAX && ((UInt64)1 << (e + 1)) * 32 <= size)
    e++;
  return e;
}

SizeT Transpose_Convert(unsigned R, unsigned stepExp, Byte *data,
    SizeT size, Byte *tmp, int encode)
{
  const SizeT n = (SizeT)1 << stepExp;
  const SizeT blk = (SizeT)R << stepExp;
  SizeT done = 0;
  while (size - done >= blk)
  {
    SizeT c, i;
    if (encode)
    {
      for (c = 0; c < R; c++)
        for (i = 0; i < n; i++)
          tmp[c * n + i] = data[done + i * R + c];
    }
    else
    {
      for (c = 0; c < R; c++)
        for (i = 0; i < n; i++)
          tmp[i * R + c] = data[done + c * n + i];
    }
    memcpy(data + done, tmp, blk);
    done += blk;
  }
  return done;
}

SizeT Transpose_Encode(unsigned R, unsigned exp, Byte *data, SizeT size, Byte *tmp)
{
  return Transpose_Convert(R, Transpose_StepExp(R, exp), data, size, tmp, 1);
}

/* --- Detection de la periode ------------------------------------------------
   On NE cherche PAS une periodicite : on cherche si transposer AIDE, ce qui
   n'est pas la meme chose. Mesure sur echantillon (validee contre la verite
   terrain sur 30 fichiers) : l'ecart absolu moyen entre octets distants de R.

     mad(L) = moyenne de |data[i] - data[i-L]|

   Transposer avec R rend adjacents les octets distants de R. Cela n'aide que
   si mad(R) est NETTEMENT plus bas que mad(1), c'est-a-dire si une colonne est
   plus homogene que le flux brut. Sans marge franche on renvoie 1 = identite.

   Un detecteur par autocorrelation a ete essaye puis REJETE : il voyait des
   periodes partout (bandes laterales des harmoniques) et degradait 7 fichiers
   sur 10, parfois lourdement (107 607 -> 137 309 octets). La periodicite d'un
   signal ne dit rien sur l'homogeneite de ses colonnes. */

/* mad(R) doit valoir au plus 70 % de mad(1) pour que le filtre s'active. */
#define TRANSPOSE_MARGE_NUM 70
#define TRANSPOSE_MARGE_DEN 100

static UInt64 Transpose_Mad(const Byte *d, SizeT n, unsigned L)
{
  UInt64 s = 0;
  SizeT i;
  for (i = L; i < n; i++)
  {
    const int diff = (int)d[i] - (int)d[i - L];
    s += (UInt64)(diff < 0 ? -diff : diff);
  }
  return s;
}

unsigned Transpose_DetectR(const Byte *data, SizeT size)
{
  SizeT n = (size < TRANSPOSE_SAMPLE) ? size : TRANSPOSE_SAMPLE;
  unsigned maxlag = TRANSPOSE_MAX_R;
  unsigned L, best = 1;
  double mad1, bestv;

  /* il faut au moins quelques enregistrements du plus grand R teste */
  if (n < (SizeT)4 * maxlag)
    return 1;

  mad1 = (double)Transpose_Mad(data, n, 1) / (double)(n - 1);
  if (mad1 <= 0)
    return 1;   /* flux constant : rien a gagner */

  bestv = mad1;
  for (L = 2; L <= maxlag; L++)
  {
    const double v = (double)Transpose_Mad(data, n, L) / (double)(n - L);
    if (v < bestv)
    {
      bestv = v;
      best = L;
    }
  }

  if (bestv * TRANSPOSE_MARGE_DEN > mad1 * TRANSPOSE_MARGE_NUM)
    return 1;   /* pas de colonne franchement plus homogene : on ne touche a rien */
  return best;
}

/* --- Mode calcul ------------------------------------------------------------
   L'heuristique ci-dessus se trompe parfois (elle est volontairement prudente).
   Ici on tranche par la mesure : on transpose un echantillon avec chacun des
   R les plus prometteurs, on le compresse pour de vrai en LZMA, et on garde
   celui qui rend le plus petit resultat. R=1 est toujours en lice, donc le
   mode calcul ne peut pas etre pire que ne rien faire. */

static SizeT Transpose_LzmaSize(const Byte *src, SizeT len)
{
  CLzmaEncProps props;
  Byte propsEnc[LZMA_PROPS_SIZE];
  SizeT propsSize = LZMA_PROPS_SIZE;
  SizeT destLen = len + len / 3 + 128;
  Byte *dest = (Byte *)ISzAlloc_Alloc(&g_Alloc, destLen);
  SRes res;
  if (!dest)
    return (SizeT)-1;
  LzmaEncProps_Init(&props);
  /* La sonde doit RESSEMBLER au codeur reel, sinon elle classe a l'envers :
     avec un dictionnaire de 1 Mo elle jugeait R=1 meilleur que R=15 sur un
     fichier ou LZMA2 en d=64m prefere nettement R=15 (28974 contre 23456). */
  props.level = 9;
  props.dictSize = 1 << 26;        /* 64 Mo, comme -mx=9 */
  props.numThreads = 1;
  res = LzmaEncode(dest, &destLen, src, len, &props, propsEnc, &propsSize, 0,
                   NULL, &g_Alloc, &g_BigAlloc);
  ISzAlloc_Free(&g_Alloc, dest);
  return (res == SZ_OK) ? destLen : (SizeT)-1;
}

/* Sortie qui ne garde rien : on ne veut que la TAILLE produite. */
typedef struct { IByteOut vt; UInt64 count; } CTransposeCountOut;
static void TransposeCountOut_Write(IByteOutPtr pp, Byte b)
{
  CTransposeCountOut *p = Z7_CONTAINER_FROM_VTBL(pp, CTransposeCountOut, vt);
  UNUSED_VAR(b)
  p->count++;
}

static SizeT Transpose_PpmdSize(const Byte *src, SizeT len)
{
  CPpmd7 ppmd;
  CTransposeCountOut out;
  out.vt.Write = TransposeCountOut_Write;
  out.count = 0;
  Ppmd7_Construct(&ppmd);
  if (!Ppmd7_Alloc(&ppmd, 16u << 20, &g_BigAlloc))
    return (SizeT)-1;
  ppmd.rc.enc.Stream = &out.vt;
  Ppmd7z_Init_RangeEnc(&ppmd);
  Ppmd7_Init(&ppmd, 16);
  Ppmd7z_EncodeSymbols(&ppmd, src, src + len);
  Ppmd7z_Flush_RangeEnc(&ppmd);
  Ppmd7_Free(&ppmd, &g_BigAlloc);
  return (SizeT)out.count;
}

static SizeT Transpose_ProbeSize(const Byte *src, SizeT len, unsigned probe)
{
  return (probe == TRANSPOSE_PROBE_PPMD) ? Transpose_PpmdSize(src, len)
                                         : Transpose_LzmaSize(src, len);
}

unsigned Transpose_MeasureR(const Byte *data, SizeT size, unsigned exp, unsigned probe)
{
  SizeT n = (size < TRANSPOSE_MEASURE_SAMPLE) ? size : TRANSPOSE_MEASURE_SAMPLE;
  unsigned cands[TRANSPOSE_MEASURE_CANDS];
  unsigned nc = 0, L, i, best = 1;
  double mad[TRANSPOSE_MAX_R + 1];
  SizeT bestSize;
  Byte *buf, *tmp;

  if (n < (SizeT)4 * TRANSPOSE_MAX_R)
    return 1;

  /* classement prealable : on ne mesure pas les 256 valeurs, seulement les
     plus prometteuses selon l'ecart absolu moyen. */
  for (L = 1; L <= TRANSPOSE_MAX_R; L++)
    mad[L] = (double)Transpose_Mad(data, n, L) / (double)(n - L);
  for (i = 0; i < TRANSPOSE_MEASURE_CANDS; i++)
  {
    unsigned pick = 0;
    double bv = 0;
    for (L = 2; L <= TRANSPOSE_MAX_R; L++)
      if (mad[L] >= 0 && (pick == 0 || mad[L] < bv)) { bv = mad[L]; pick = L; }
    if (!pick) break;
    cands[nc++] = pick;
    mad[pick] = -1;               /* retire du classement */
  }

  bestSize = Transpose_ProbeSize(data, n, probe);   /* reference : R=1, aucune transposition */
  if (bestSize == (SizeT)-1)
    return 1;

  buf = (Byte *)ISzAlloc_Alloc(&g_Alloc, n);
  tmp = (Byte *)ISzAlloc_Alloc(&g_Alloc, (size_t)1 << exp);
  if (!buf || !tmp)
  {
    if (buf) ISzAlloc_Free(&g_Alloc, buf);
    if (tmp) ISzAlloc_Free(&g_Alloc, tmp);
    return 1;
  }

  for (i = 0; i < nc; i++)
  {
    SizeT got;
    memcpy(buf, data, n);
    Transpose_Encode(cands[i], exp, buf, n, tmp);
    got = Transpose_ProbeSize(buf, n, probe);
    if (got != (SizeT)-1 && got < bestSize) { bestSize = got; best = cands[i]; }
  }

  ISzAlloc_Free(&g_Alloc, buf);
  ISzAlloc_Free(&g_Alloc, tmp);
  return best;
}

/* --- Choix sur le fichier entier (passe prealable) --------------------------
   Trois etapes, de la moins chere a la plus chere :
     1. une compression de reference a R=1, dont on a besoin de toute facon ;
        si le fichier compresse deja tres bien, on s'arrete la ;
     2. un classement gratuit par ecart absolu moyen, qui donne un candidat ;
     3. un classement par un codeur RAPIDE (LZMA niveau 1), qui en donne un
        second — les deux sondes voient des choses differentes : l'ecart moyen
        rate les resonances que seul un chercheur de repetitions voit, et le
        codeur rapide rate les redondances purement statistiques.
   Puis on compresse pour de vrai ces deux candidats au plus, et on garde le
   meilleur des trois resultats. */

static SizeT Transpose_FastSize(const Byte *src, SizeT len)
{
  CLzmaEncProps props;
  Byte propsEnc[LZMA_PROPS_SIZE];
  SizeT propsSize = LZMA_PROPS_SIZE;
  SizeT destLen = len + len / 3 + 128;
  Byte *dest = (Byte *)ISzAlloc_Alloc(&g_Alloc, destLen);
  SRes res;
  if (!dest)
    return (SizeT)-1;
  LzmaEncProps_Init(&props);
  props.level = 1;                 /* on classe, on ne livre pas */
  props.dictSize = 1 << 18;
  props.numThreads = 1;
  res = LzmaEncode(dest, &destLen, src, len, &props, propsEnc, &propsSize, 0,
                   NULL, &g_Alloc, &g_BigAlloc);
  ISzAlloc_Free(&g_Alloc, dest);
  return (res == SZ_OK) ? destLen : (SizeT)-1;
}

/* Poids relatifs pour la barre de progression. Une sonde PPMd porte sur tout
   le tampon (jusqu'a 64 Mo) et coute environ un ordre de grandeur de plus par
   octet qu'une sonde LZMA-1 sur l'echantillon de triage : la barre serait
   mensongere a compter les etapes a poids egal. */
#define TP_W_TRIAGE 1
#define TP_W_PROBE  8

static int Transpose_Tick(ITransposeProgress *prog, UInt64 done, UInt64 total)
{
  return prog ? prog->Progress(prog, done, total) : 0;
}

unsigned Transpose_ChooseR_Full(const Byte *data, SizeT size, unsigned exp, unsigned probe,
    int partial, ITransposeProgress *prog)
{
  static const unsigned CS[] = { 2,3,4,6,8,12,16,24,32,44,48,64,88,96,128,176,192,224,256 };
  const unsigned nCS = (unsigned)(sizeof(CS) / sizeof(CS[0]));
  unsigned i, best = 1, cand[2];
  unsigned nCand = 0;
  SizeT baseline, bestSize, tri;
  double mad1, madBest = 0, fast1, fastBest = 0;
  unsigned madR = 0, fastR = 0;
  Byte *buf, *tmp;
  UInt64 done = 0;
  const UInt64 total = (UInt64)TP_W_TRIAGE * (2 + nCS) + (UInt64)TP_W_PROBE * 3;

  if (size < (SizeT)4 * TRANSPOSE_MAX_R)
    return 1;

  /* ---------------------------------------------------------------------
     PHASE 1 — TRIAGE. Uniquement des sondes bon marche, et sur un
     echantillon, pas sur tout le tampon.

     L'ordre compte. La version precedente payait d'abord la sonde PPMd sur
     l'integralite du tampon, puis cherchait des candidats — et rendait R=1
     sans en avoir trouve un seul. Sur du contenu deja compresse (video, JPEG)
     ce travail etait donc integralement perdu, pour des minutes d'attente
     pendant lesquelles la fenetre paraissait figee.

     La reference PPMd ne sert qu'a etre COMPAREE a des candidats. S'il n'y a
     aucun candidat, il n'y a rien a comparer : on sort avant de la payer.
     --------------------------------------------------------------------- */

  tri = (size < (SizeT)TRANSPOSE_TRIAGE_SAMPLE) ? size : (SizeT)TRANSPOSE_TRIAGE_SAMPLE;

  buf = (Byte *)ISzAlloc_Alloc(&g_Alloc, tri);
  tmp = (Byte *)ISzAlloc_Alloc(&g_Alloc, (size_t)1 << exp);
  if (!buf || !tmp)
  {
    if (buf) ISzAlloc_Free(&g_Alloc, buf);
    if (tmp) ISzAlloc_Free(&g_Alloc, tmp);
    return 1;
  }

  /* 1a. reference du codeur rapide, pour le classement 1c.

     Il y avait ici un garde-fou « deja tres compressible (>= 10x) ? alors on
     abandonne, transposer ne peut que nuire ». Il est RETIRE.

     Deux raisons, la seconde mesuree. D'abord il ne protegeait de rien : le
     verdict final est un minimum qui inclut toujours R=1, donc la degradation
     est deja impossible par construction ; ce garde-fou ne pouvait que faire
     PERDRE du gain. Ensuite, l'evaluer au codeur rapide le rendait franchement
     nuisible — c_int32.bin (entiers consecutifs) est tres repetitif, LZMA-1 y
     depasse le seuil de 10x la ou PPMd restait dessous : le garde-fou se
     declenchait et rendait R=1 au lieu de R=4. Mesure : R=4 retrouve, et
     l'attente supprimee par le triage rend le garde-fou inutile. */
  fast1 = (double)Transpose_FastSize(data, tri);
  done += TP_W_TRIAGE;
  if (Transpose_Tick(prog, done, total)) goto abandon;

  /* 1b. classement par ecart absolu moyen. On balaye TOUTES les valeurs de 2 a
     256, pas une grille : une grille rate les periodes intermediaires —
     mesure : l'optimum d'un fichier de test est R=15, absent de toute grille
     raisonnable, et le rater coute 27 %. */
  mad1 = (double)Transpose_Mad(data, tri, 1) / (double)(tri - 1);
  if (mad1 > 0)
  {
    unsigned L;
    for (L = 2; L <= TRANSPOSE_MAX_R; L++)
    {
      double v;
      if ((SizeT)L >= tri) break;
      v = (double)Transpose_Mad(data, tri, L) / (double)(tri - L);
      if (madR == 0 || v < madBest) { madBest = v; madR = L; }
    }
  }
  done += TP_W_TRIAGE;
  if (Transpose_Tick(prog, done, total)) goto abandon;
  /* Seuil volontairement LARGE : le verdict final vient de compressions
     reelles ou R=1 est toujours en lice, donc un candidat de trop ne coute que
     du temps, jamais de la justesse. Un seuil serre (0,30) ratait 85 % de gain
     sur des releves de capteurs float, dont l'ecart moyen tombe a 0,52. */
  if (madR && madBest < 0.90 * mad1)
    cand[nCand++] = madR;

  /* 1c. classement par codeur rapide */
  if (fast1 > 0)
    for (i = 0; i < nCS; i++)
    {
      double v;
      if ((SizeT)CS[i] >= tri) break;
      memcpy(buf, data, tri);
      Transpose_Encode(CS[i], exp, buf, tri, tmp);
      v = (double)Transpose_FastSize(buf, tri);
      if (v > 0 && (fastR == 0 || v < fastBest)) { fastBest = v; fastR = CS[i]; }
      done += TP_W_TRIAGE;
      if (Transpose_Tick(prog, done, total)) goto abandon;
    }
  if (fastR && fastBest < 0.90 * fast1 && fastR != madR && nCand < 2)
    cand[nCand++] = fastR;

  ISzAlloc_Free(&g_Alloc, buf);
  buf = NULL;

  /* Aucun candidat : rien a departager, on ne paie pas la sonde chere. */
  if (nCand == 0)
    goto abandon;

  /* ---------------------------------------------------------------------
     PHASE 2 — VERDICT par compressions REELLES sur tout le tampon, R=1
     toujours en lice. C'est ce qui rend la degradation impossible par
     construction : le resultat retenu est un minimum qui inclut toujours la
     taille sans filtre.
     --------------------------------------------------------------------- */

  buf = (Byte *)ISzAlloc_Alloc(&g_Alloc, size);
  if (!buf)
    goto abandon;

  baseline = Transpose_ProbeSize(data, size, probe);
  done += TP_W_PROBE;
  if (Transpose_Tick(prog, done, total)) goto abandon;
  if (baseline == (SizeT)-1 || baseline == 0)
    goto abandon;

  bestSize = baseline;
  for (i = 0; i < nCand; i++)
  {
    SizeT got;
    memcpy(buf, data, size);
    Transpose_Encode(cand[i], exp, buf, size, tmp);
    got = Transpose_ProbeSize(buf, size, probe);
    if (got != (SizeT)-1 && got < bestSize) { bestSize = got; best = cand[i]; }
    done += TP_W_PROBE;
    if (Transpose_Tick(prog, done, total)) { best = 1; goto abandon; }
  }
  /* Si la decision porte sur un prefixe et non sur tout le fichier, la
     garantie ci-dessus ne tient plus : on exige alors une marge franche. */
  if (partial && best != 1 && (double)bestSize > TRANSPOSE_PREFIX_MARGIN * (double)baseline)
    best = 1;

abandon:
  if (buf) ISzAlloc_Free(&g_Alloc, buf);
  if (tmp) ISzAlloc_Free(&g_Alloc, tmp);
  Transpose_Tick(prog, total, total);
  return best;
}
