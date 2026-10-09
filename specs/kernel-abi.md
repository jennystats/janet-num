# Spec - janet-num kernel ABI contract (v1, libjn 0.1.0)

Non-Quint specification (interface contract). Canonical signatures:
the module docstrings. This document adds what
signatures cannot carry: preconditions, effects, status semantics,
and the memory contract. Misuse of a C ABI produces memory errors
that tests catch late - this contract is the cheap insurance.
Binding truth: `janet-num.janet` (ffi/defbind + wrappers);
C truth: `libs/janet-num.c`.

## 1. Layering

- **Janet wrapper layer** (janet-num.janet): validation,
  buffer creation, handle construction, actionable errors. ALL
  argument validation lives in this layer - natively in wrapper code
  or by calling validating core primitives (ffi/write, §2) - the C
  layer trusts its caller.
- **C kernel layer** (libs/janet-num.c): plain functions, no Janet
  symbols, no validation, no allocation, no global state.

## 2. Memory contract (normative)

- **Handles** are structs `{:ptr <Janet buffer> :n <count>
  :bytes <n × elem-bytes> :free <no-op fn> :close <no-op fn>}`.
  `:ptr` marshals as pointer-to-buffer-data. `:free` and `:close` are
  documented NO-OPs; `with` calls `:close` (measured 2026-10-04:
  `:free` alone was NOT with-compatible - the doc claim was wrong,
  `:close` added). Buffers are GC-managed Janet buffers staged via
  `ffi/write`, never ffi/malloc. Caller-side reachability is still
  required (an early lesson): keep the handle alive through the call.
- **WRAPPER VALIDATION (2026-10-04)**: element WIDTH is
  validated per call (`:bytes` = width × `:n`; an i32 handle into an
  8-byte kernel measured as a SILENT heap overread before this);
  matrix lanes check their explicit dims against the handle's `:n`;
  OPCODES are validated against per-entrypoint sets (the C switches
  fell through to a silent identity COPY for unimplemented ops -
  vscan :sumsq, vmap1 :add, vmap1-scalar :abs measured). Packers
  validate emptiness wrapper-side and reject string elements
  wrapper-side (the 64-bit primitives would parse bare strings
  silently, including hex); every other element check is the
  primitive's native per-element validation, whose errors name the
  offending value (2026-10-05: wrapper loops duplicating those
  checks cost 15-56x the pack itself and were deleted);
  `pack-i64` exists (the i64
  lanes previously had no packer - s64 boxes through pack-u64 work
  bit-exact but that route is now documented, not required).
- **NEVER-ALLOCATE**: kernels write only into caller-provided out
  buffers. Out buffers are FRESH Janet buffers created by the
  wrapper (`new-out`). In-place kernels (below) write into an input.
- **Workspaces are caller-staged**: `lu-solve`'s n×n scratch is
  created by the wrapper (`new-out (* n n))`) and passed to the
  kernel; the kernel never sizes or allocates it.
- Element sizes: f64 = 8 bytes, i64 = 8, i32 = 4, u64 = 8.

## 3. Status and error semantics

- **int-status kernels** (cholesky-l, chol-solve, lu-solve): return
  `1` = ok, `0` = failure (not-SPD; zero diagonal; near-singular
  pivot < 1e-300). Wrappers translate 0 into actionable Janet errors.
- **Value kernels** (everything else) have NO failure mode: NaN in,
  NaN out (the domain contract is documented per function).
- **Wrapper-level errors** (before any C call): length mismatch
  (check-same-n), element-width mismatch (check-h), dims-vs-handle
  (matrix lanes), unknown/unimplemented op (per-entrypoint sets),
  empty buffers, empty packer arrays, string packer elements - all
  actionable with the offending values named. Other packer element
  errors are the primitives' native messages (§2), raised before any
  kernel call.
- **Accumulation**: strictly sequential, no reassociation, no
  -ffast-math - bitwise agreement with the pure-Janet oracles is the
  conformance bar. Integer arithmetic runs through unsigned
  internally: wraparound is defined behaviour, never UB.

## 4. Per-kernel contract

Legend: P = preconditions (wrapper-enforced unless noted),
E = effects, S = status.

| kernel (Janet) | C signature | P | E / S |
|---|---|---|---|
| pack-columns-f32/f64 | jn_interleave_f32/f64(cols-ptr, ncol, nrow, out) | cols non-empty, equal lengths | row-major packed handle `{:nrow :ncol}`; SHARED staging (one buffer, per-column offsets) |
| unpack-columns-f32/f64 | jn_deinterleave_* | packed has :nrow/:ncol | array of column arrays (buffer→array via ffi/read) |
| interleave-chunk-f32 [_null] | jn_interleave_f32[_null] | C-to-C lane: raw pointer tables + masks; CALLER owns all memory | rows at row-offset; invalid → NaN |
| band/bor/bxor | jn_b*_u64(a,b,n,out) | equal n | new u64 handle |
| popcount | jn_popcount_u64(a,n,out) | - | per-word counts handle |
| vmap1/vmap1-scalar | jn_vmap1_f64/jn_vmap1s_f64(op,...) | op ∈ enum (add sub mul div min max abs neg; vmap1 ALSO exp log) | elementwise out |
| vmap2, vzip, vdot | jn_vmap2/vzip/vdot_f64 | equal n | out / fused scalar |
| vreduce, vscan | jn_vreduce/vscan_f64(op,...) | op ∈ enum | scalar / cumulative out |
| vaxpy | jn_vaxpy_f64(alpha,x,y,n) | equal n | **IN-PLACE into y** (the ONE canonical in-place op); returns y |
| i64/i32 subsets | jn_*_i64/_i32 | as f64 analogues | defined wraparound (§3) |
| erf-v, erfc-v, lgamma-v | jn_*_f64(a,n,out) | - | elementwise (libm; lgamma_r reentrant) |
| log-beta-v | jn_log_beta_f64(a,b,n,out) | equal n | elementwise |
| gamma-p-v, gamma-q-v | jn_gamma_[pq]_f64(a,x,n,out) | equal n; a>0, x≥0 | elementwise CF/series forms |
| beta-inc-v | jn_beta_inc_f64(a,b,x,n,out) | equal n; a,b>0, 0≤x≤1 | elementwise |
| pnorm-v | jn_pnorm_f64(a,mean,sd,n,out) | sd≠0 (wrapper: sd≠0 enforced) | fused erfc sign-branch CDF |
| ptukey-v | jn_ptukey_f64(q,nmeans,df,nranges,n,out) | handle 8-byte; domain nmeans≥2, df≥2, nranges≥1 is CALLER-side (the stats layer validates - mirrors the pure); NaN in ANY arg (q/nmeans/df/nranges) → a NaN out (R's ptukey.c ISNAN gate, the full 4-arg form). TWO branches, tested FIRST (before the q≤0/+inf poles): q-NaN → the caller's NaN unchanged (preserves payload/sign per §3 "NaN in, NaN out" - a deliberate DEVIATION from R's ML_WARN_return_NAN, which returns a canonical ML_NaN for any-arg NaN; R's surface cannot distinguish payload/sign, so the deviation is unobservable through R); param-NaN (nmeans/df/nranges) → NaN (a canonical NaN, R's ML_WARN_return_NAN - NOT q, which would be a FINITE value for finite q). THEN q≤0 → 0, q=+inf → 1 (R's poles); PARAM POLES (df=0, negative even df: the lgamma poles): the pure throws its helper's error, the kernel returns the decoded value - unreachable through the stats layer (df≥2 validated) | elementwise studentized-range CDF: mirrors the R-verified pure's quadrature (Copenhaver-Holland), libm phi/lgamma vs the pure's helpers; parity bar ≤1e-9 rel (measured 1.0e-13 across the A9 grid; the band grows with k/nranges - worst 1.5e-11 across the wider probe grid, ~100x under the bar); scalar (nmeans,df,nranges) broadcast over the q vector (R's TukeyHSD fixes k per call) |
| matvec | jn_matvec_f64(m,v,n,p,out) | m is n×p packed; v is p | n-vector out |
| matmul | jn_matmul_f64(a,b,m,k,n,out) | a is m×k, b is k×n | m×n row-major out |
| dist2-rows | jn_dist2_rows_f64(x,c,n,p,k,out) | x n×p, c k×p | n×k squared distances |
| cholesky-l | jn_cholesky_f64(a,n,out) | a n×n SYMMETRIC (kernel checks s≤0 → S=0) | E: out = lower L (A = LL′); S: 1 ok / 0 not-SPD |
| chol-solve | jn_chol_solve_f64(l,b,n) | l lower n×n, nonzero diag | **IN-PLACE: b's buffer becomes x** (solves LL′x=b); S: 1 / 0 |
| lu-solve | jn_lu_solve_f64(a,b,n,work) | a n×n; work n×n staged (§2) | **IN-PLACE into b**; partial-pivot; S: 1 / 0 near-singular |

## 5. Binding + build discipline

- Resolution: `$JANET_NUM_LIB` → `~/.local/lib/janet-num/libjn.so` →
  dlopen search; import failure names the installer (actionable).
- The installer verifies the source sha256 BEFORE compiling
  (`gcc -O2 -shared -fPIC`; no -march; plain -O2, autovectorize).
- The module's version string is asserted by its own smoke - EVERY
  version change bumps it (measured footgun); kernel changes
  re-pin the sha256. **0.1.0 (2026-10-09) = first published release**,
  folding in the pre-release milestones: completion of the public
  surface (2026-10-03) - the public functions landed (kernel-backed or
  documented composition), the default impl flipped to `:impl`
  (dynamic - :num on present machines, :pure when absent); the
  ptukey kernel (2026-10-05, new-kernel
  addition, the §6 minor-bump middle); the ptukey kernel's
  NaN-pole semantics fix (2026-10-06, the §6 semantics-amendment
  middle) and its follow-up: the ISNAN gate widened to the full 4-arg form and returns the
  caller's NaN (payload/sign preserved), then split into two branches
  - q-NaN preserves the caller's NaN (a deliberate deviation from R's
  ML_WARN_return_NaN, which returns a canonical ML_NaN for any-arg
  NaN; R's surface cannot distinguish payload/sign); param-NaN returns
  a canonical NaN (R's ML_WARN_return_NAN), fixing the
  finite-value return for finite q + param-NaN.

## 6. Change protocol

A new kernel = a new row in §4 + requirements §3 + its consumer
extension policy - never an ad-hoc symbol.
An ABI change to an existing kernel (signature, effects, status
semantics) is a BREAKING change: version bump + smoke update + the
affected consumers re-verified in the same commit. OP-CODE ADDITIONS
(the op-code precedent) are the compatible middle: same signatures,
new enum values - minor bump + sha re-pin + smoke rows + consumers
re-verified, all in the same commit. NEW-KERNEL ADDITIONS (the
ptukey precedent) are the same compatible middle: a new
symbol changes no existing signature - minor bump + sha re-pin +
smoke rows + consumers re-verified, all in the same commit. SEMANTICS AMENDMENTS (the
ptukey-pole precedent) are the same compatible middle: a documented
domain-contract decode correction - no signature, effect, or status
change - minor bump + sha re-pin + smoke rows + consumers re-verified,
all in the same commit. The
mirror rule for statistics kernels: the C mirrors the stats
module's R-verified pure (same integration scheme, same constants
and break rules) - never an independent reimplementation. NOTE: the
SEMANTICS AMENDMENTS clause is a NEW rule, SET by the ptukey-pole
change (the precedent is being SET, not followed) - it did not exist
in this contract before that change introduced it alongside what it
classifies.
