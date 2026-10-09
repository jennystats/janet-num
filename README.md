# janet-num

Small C kernels for Janet's numeric hot paths, called via core ffi - a
plain shared library, not a jpm native module. It runs on any Janet
build with ffi, builds from pinned source at install time, and puts no
Janet symbols in the runtime.

Part of [Jenny Stats](https://github.com/jennystats), a home for Janet
data and statistics packages. Jenny is just Janet.

The in-REPL reference: `(doc janet-num)` lists the families, and every
public function documents its contract via `(doc janet-num/<name>)`.

## What and why, measured

Janet's numeric loops pay interpreter dispatch per element; the
kernels pay it once per call. Measured at 1M elements, kernel vs pure
Janet, min-of-5, one harness:

| family | speedup vs pure |
|---|---|
| vmap2 (add, mul) | 43-59x |
| vdot | 38-40x |
| vreduce (sum, min) | 114-180x |
| specfun (erf and friends) | 40-1224x |
| ptukey (studentized range, pairwise-CI shapes) | 617-828x |
| matmul | 89-126x |
| i64 lanes | 49-486x |
| bitops (band, bor, bxor) | 22x |
| popcount | 562x |

Kernel costs are 0.4-24 ns per element; pure Janet loops run 50-65 ns
per element and maps 200-350. At n=100 the floor is 2.5-8x (an ffi call
costs about 30 ns). Packing is one pass - pack-f64 5.1 ns/e, unpack
7.7, pack-i32 7.6 - a round trip costs about 1.5 kernel ops, and the
packed path wins at every n measured: 2.2x at n=100 with one op,
7.2-10.9x at 1k-1M, 31-93x at sixteen ops. There is no crossing point
to wait for. The i64/u64 packers add a wrapper-side string-element
guard and bench 51-60 ns/e.

Allocation-inclusive cells drift between runs (7-15 ns/e on the same
day; allocation-free reductions move less than 5%), so ratios compare
within one run. Reproduce the pack cells (min of 5, 1M elements; a
cold process lands at the top of the drift band):

```bash
janet -e '(import janet-num)
(def xs (seq [i :range [0 1000000]] i))
(each [nm f] [["pack-f64" janet-num/pack-f64] ["pack-i32" janet-num/pack-i32] ["pack-u64" janet-num/pack-u64] ["pack-i64" janet-num/pack-i64]]
  (var best math/inf)
  (for _ 0 5 (f xs) (def t0 (os/clock)) (f xs) (def d (- (os/clock) t0)) (when (< d best) (set best d)))
  (printf "%s 1e6: %.1f ns/e\n" nm (* 1000 best)))'
```

## Gotchas

- `band`/`bor`/`bxor` shadow the core bitops under
  `(import janet-num :prefix "")` - capture the core fns first if you
  need both.
- Packer element errors are the primitives' native messages: ffi/write
  reports `bad slot #1, expected number, got "x"` (element index and
  offending value), the 64-bit conversions report `can not convert
  number 1.5 to 64 bit signed integer`. Empty arrays and string
  elements keep `janet-num:`-prefixed errors - the 64-bit primitives
  would parse bare strings silently (including hex), so the i64/u64
  packers reject them wrapper-side. Plain doubles cap at 2^53 in the
  i64/u64 packers - pack larger values as `(int/s64 "...")` boxes, and
  negative u64 words as s64 boxes (bit-exact two's complement).
- `unpack-u64` returns `int/u64` boxes: identity-compared (`=` is
  false for equal values), `int/to-number` caps at the double-safe
  range, and the box constructors reinterpret bits. Exact comparison
  route: `(string (int/s64 box))` on both sides.
- The packed layout is native-endian. Marshal buffers explicitly if
  they leave the machine; there is no cross-endian exchange story.
- The kernels never allocate; buffers are Janet-owned and
  GC-managed. The handle's `:free` is a no-op kept for `with`
  compatibility - `:close` is what `with` calls.

## Alternatives

- **[tarray](https://github.com/janet-lang/tarray)** - Janet's typed
  arrays: storage (u8..f64 views, stride and offset, slice and
  copy-bytes) as a native jpm module built per Janet version.
  janet-num is the compute half - kernels, reductions, dot products,
  bitops, specfun, matrix ops - via core ffi, source-built at install.
  Different halves of the same problem. No direct interop today:
  tarray buffers are abstracts, not Janet buffers, so a bridge would
  copy or take a raw-pointer lane.

## Install

The kernels are a C library; build once with the pinned installer
(verified sha256, gcc, idempotent):

```bash
libs/install-janet-num.sh   # builds ~/.local/lib/janet-num/libjn.so
```

Then either import by path, symlink `janet-num.janet` into your module
directory, or:

```bash
jpm install https://github.com/jennystats/janet-num
```

Lib resolution on import: `$JANET_NUM_LIB`, then
`~/.local/lib/janet-num/libjn.so`, then dlopen search. The import
fails with an actionable message if none loads.

## Tests

```bash
./run_tests.sh
```

The smoke uses pure Janet loops as the oracle (bitwise for f64 paths)
and skips cleanly when libjn is absent.

## License

AGPLv3 - see `LICENSE`.

## AI assistance

The code in this repository was written with the assistance of a large
language model and reviewed by its maintainer.
