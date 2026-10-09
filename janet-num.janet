# janet-num.janet - small C kernels for Janet's numeric hot paths,
# called via core ffi. Public package: janet-num. License: AGPLv3 (see
# LICENSE). Plain library (built from pinned source by
# libs/install-janet-num.sh - NOT a native module; no Janet symbols,
# same class as the engine libs).
#
# Memory model: ALL packed buffers are Janet BUFFERS - ffi/write
# returns a GC-managed buffer (verified), and kernels write into
# (buffer/new-filled) buffers passed as :ptr. No ffi/malloc, no
# ffi/free, no manual ownership anywhere; `:free` is a documented
# no-op kept for `with` and handle-shape compatibility. Kernels never
# allocate on their own either (see libs/janet-num.c).
#
# Slice 1: pack/unpack + integer/bitset kernels (band/bor/bxor/
# popcount over packed u64 - bit-set workloads).
# The pack kernels transpose column-major to row-major packed in one
# C pass.
#
# Lib resolution: $JANET_NUM_LIB -> ~/.local/lib/janet-num/libjn.so ->
# dlopen search. Import fails actionably if none loads.

# Module envs inherit ROOT dyns, not the requiring env's - a plain
# `janet script.janet` whose top-level setdyn self-heal cannot reach
# this module's fresh env would fail to find typed here (found
# 2026-10-08; the earlier heal also clobbered valid inherited
# syspaths). Heal ONLY when HOME is set and the
# inherited syspath is empty or the compile default (never clobber a
# $JANET_PATH-seeded one): set the FIRST EXISTING dir of the short
# list, single dir, no concatenation (*syspath* is not
# PATH-separated). Formal spec: specs/syspath-heal.qnt (quint).
(def _home (get (os/environ) "HOME"))
(def _inherited (string (or (dyn *syspath*) "")))
(def _compile-default "/usr/local/lib/janet")
(defn _dir-exists [p]
  # a regular file at a candidate path must not win the scan -
  # existence alone is not dir-ness
  (def s (try (os/stat p) ([_] nil)))
  (and s (= (s :mode) :directory)))
(when (and _home (not (empty? _home))
           (or (empty? _inherited) (= _inherited _compile-default)))
  (def _candidates [(string _home "/.local/lib/janet")
                    _compile-default
                    "/usr/lib/janet"])
  (def _first-existing (find _dir-exists _candidates))
  (when _first-existing (setdyn *syspath* _first-existing)))

# typed must resolve here or nothing else can. Two distinct failure
# classes, distinct remedies: not-found names $JANET_PATH;
# found-but-broken rethrows the loader's own error - a wrong remedy is
# worse than none. The lib stage comes after and is never the cause of
# a typed failure.
(def _typed-found (try (first (module/find "typed")) ([_] nil)))
(var _typed-err nil)
(unless (try (do (import typed :prefix "") true) ([e] (set _typed-err e) false))
  (if _typed-found
    (errorf "janet-num: cannot load typed from %s - %s" _typed-found _typed-err)
    (errorf "janet-num: cannot find typed under %s - set $JANET_PATH to a directory containing typed.janet"
            (or (dyn *syspath*) "(none)"))))

(put (curenv) :doc
     "Small C kernels for Janet's numeric hot paths, called via core ffi.
Packed buffers are the currency: pack flat arrays or column-major
tables with the pack fns, compute on handles, unpack or read views back
out. Families: pack/unpack (flat and column forms, f32 f64 i32 i64
u64); bitops band/bor/bxor/popcount over packed u64; elementwise
vmap1/vmap2/vmap1-scalar; reductions vreduce/vscan across f64, i64 and
i32 lanes; vzip/vdot/vaxpy; matrix kernels matvec/matmul/dist2-rows/
cholesky-l/chol-solve/lu-solve; special functions erf-v erfc-v
lgamma-v log-beta-v gamma-p-v gamma-q-v beta-inc-v pnorm-v ptukey-v;
and packed-slice-f32/f64 views. Preconditions and status semantics:
specs/kernel-abi.md is the contract; these docstrings are its public
mirror.")

#==------------------------------------------------------------------------==#
# Lib resolution
#==------------------------------------------------------------------------==#

(defn/typed lib-path {:args [] :ret :string} []
  "Kernel library path: $JANET_NUM_LIB, then the pinned
  ~/.local/lib/janet-num/libjn.so, then bare dlopen search."
  (def env (get (os/environ) "JANET_NUM_LIB"))
  (if env env
    (let [home (get (os/environ) "HOME")
          pinned (string home "/.local/lib/janet-num/libjn.so")]
      (if (not (nil? (os/stat pinned))) pinned "libjn.so"))))

(def lib (lib-path))
(ffi/context lib)

(unless (try (do (ffi/native lib) true) ([_] false))
  (errorf "janet-num: cannot load %s - run libs/install-janet-num.sh (needs gcc) or set $JANET_NUM_LIB" lib))

#==------------------------------------------------------------------------==#
# Bindings (libs/janet-num.c - signatures verified against the source)
#==------------------------------------------------------------------------==#

(ffi/defbind jn_version :string [])
(ffi/defbind jn_interleave_f32 :void [cols :ptr ncol :size nrow :size out :ptr])
(ffi/defbind jn_interleave_f64 :void [cols :ptr ncol :size nrow :size out :ptr])
(ffi/defbind jn_deinterleave_f32 :void [in :ptr ncol :size nrow :size cols :ptr])
(ffi/defbind jn_deinterleave_f64 :void [in :ptr ncol :size nrow :size cols :ptr])
(ffi/defbind jn_band_u64 :void [a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_bor_u64 :void [a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_bxor_u64 :void [a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_popcount_u64 :void [a :ptr n :size out :ptr])
(ffi/defbind jn_interleave_f32_null :void [cols :ptr masks :ptr ncol :size nrow :size row-offset :size out :ptr])
(ffi/defbind jn_vmap1_f64 :void [op :int a :ptr n :size out :ptr])
(ffi/defbind jn_vmap2_f64 :void [op :int a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_vmap1s_f64 :void [op :int a :ptr k :double n :size out :ptr])
(ffi/defbind jn_vreduce_f64 :double [op :int a :ptr n :size])
(ffi/defbind jn_vscan_f64 :void [op :int a :ptr n :size out :ptr])
(ffi/defbind jn_vzip_f64 :void [a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_vdot_f64 :double [a :ptr b :ptr n :size])
(ffi/defbind jn_vaxpy_f64 :void [alpha :double x :ptr y :ptr n :size])
(ffi/defbind jn_vmap2_i64 :void [op :int a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_vmap1s_i64 :void [op :int a :ptr k :int64 n :size out :ptr])
(ffi/defbind jn_vreduce_i64 :int64 [op :int a :ptr n :size])
(ffi/defbind jn_vscan_i64 :void [op :int a :ptr n :size out :ptr])
(ffi/defbind jn_vmap2_i32 :void [op :int a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_vreduce_i32 :int64 [op :int a :ptr n :size])
(ffi/defbind jn_vscan_i32 :void [op :int a :ptr n :size out :ptr])

# slice 3: special functions + matvec + row distances (0.3.0-specfun)
(ffi/defbind jn_erf_f64 :void [a :ptr n :size out :ptr])
(ffi/defbind jn_erfc_f64 :void [a :ptr n :size out :ptr])
(ffi/defbind jn_lgamma_f64 :void [a :ptr n :size out :ptr])
(ffi/defbind jn_log_beta_f64 :void [a :ptr b :ptr n :size out :ptr])
(ffi/defbind jn_gamma_p_f64 :void [a :ptr x :ptr n :size out :ptr])
(ffi/defbind jn_gamma_q_f64 :void [a :ptr x :ptr n :size out :ptr])
(ffi/defbind jn_beta_inc_f64 :void [a :ptr b :ptr x :ptr n :size out :ptr])
(ffi/defbind jn_pnorm_f64 :void [a :ptr mean :double sd :double n :size out :ptr])
(ffi/defbind jn_ptukey_f64 :void [q :ptr nmeans :double df :double nranges :double n :size out :ptr])
(ffi/defbind jn_matvec_f64 :void [m :ptr v :ptr n :size p :size out :ptr])
(ffi/defbind jn_dist2_rows_f64 :void [x :ptr c :ptr n :size p :size k :size out :ptr])
(ffi/defbind jn_matmul_f64 :void [a :ptr b :ptr m :size k :size n :size out :ptr])
(ffi/defbind jn_cholesky_f64 :int [a :ptr n :size out :ptr])
(ffi/defbind jn_chol_solve_f64 :int [l :ptr b :ptr n :size])
(ffi/defbind jn_lu_solve_f64 :int [a :ptr b :ptr n :size work :ptr])

(defn/typed op-code {:args [:keyword] :ret :number} [op]
  "Map a vmap op keyword to its C opcode. Internal - op validation
  lives in check-op against the per-entrypoint op sets."
  (case op
    :add 0 :sub 1 :mul 2 :div 3 :min 4 :max 5 :abs 6 :neg 7
    :exp 8 :log 9
    (errorf "janet-num: unknown map op %q" op)))

(defn/typed red-code {:args [:keyword] :ret :number} [op]
  "Map a reduce op keyword to its C opcode. Internal."
  (case op
    :sum 0 :prod 1 :min 2 :max 3 :sumsq 4
    (errorf "janet-num: unknown reduce op %q" op)))

(defn/typed check-same-n {:args [:struct :struct] :ret :number} [a b]
  "Assert two handles hold the same element count; the error names
  both counts. Internal."
  (unless (= (a :n) (b :n))
    (errorf "janet-num: buffers differ in length (%d vs %d)" (a :n) (b :n)))
  (a :n))

(defn/typed check-h {:args [:struct :number :string] :ret :number} [h width who]
  "Assert the handle's :bytes is n x width - a narrower handle in a
  wider kernel is a silent heap overread, not an error. Internal."
  # count checks do not catch element-width confusion - an i32 handle
  # fed to an 8-byte kernel overreads
  # the heap silently (measured: garbage values, no error)
  (def n (h :n))
  (unless (= (h :bytes) (* width n))
    (errorf "janet-num: %s needs %d-byte elements (handle :bytes %d for n %d - wrong packer?)"
            who width (h :bytes) n))
  n)

(def op-sets
  # the C switches fall through to a
  # silent identity COPY for unimplemented ops (vscan :sumsq, vmap1
  # :add, vmap1-scalar :abs measured) - the wrapper is the validation
  # layer per the ABI doc; op sets are the contract
  {:vmap1 [:abs :neg :exp :log]
   :vmap1s [:add :sub :mul :div]
   :vmap2 [:add :sub :mul :div :min :max]
   :vmap2i [:add :sub :mul :min :max]
   :reduce [:sum :prod :min :max :sumsq]
   :scan [:sum :prod :min :max]
   :reduce64 [:sum :min :max]
   :scan64 [:sum :min :max]})

(defn/typed check-op {:args [:keyword :keyword] :ret :number} [op set-kw]
  "Validate a map op against its entrypoint's op set (see op-sets)
  and return the opcode; unimplemented ops error naming the set.
  Internal."
  (unless (index-of op (op-sets set-kw))
    (errorf "janet-num: %s does not implement %q (ops: %q)"
            set-kw op (op-sets set-kw)))
  (op-code op))

(defn/typed check-red {:args [:keyword :keyword] :ret :number} [op set-kw]
  "Validate a reduce op against its entrypoint's op set (see
  op-sets) and return the opcode. Internal."
  (unless (index-of op (op-sets set-kw))
    (errorf "janet-num: %s does not implement %q (ops: %q)"
            set-kw op (op-sets set-kw)))
  (red-code op))

(defn/typed new-out {:args [:number] :ret :any} [n]
  "Fresh zeroed out-buffer of n 8-byte elements. Internal."
  (buffer/new-filled (* 8 n) 0))

(defn/typed handle {:args [:any :number :number] :ret :struct} [buf n elem-bytes]
  "Wrap a packed buffer as the kernel handle {:ptr :n :bytes :free
  :close}. Buffers are GC-managed; :free and :close are documented
  no-ops kept so `with` works (:close is the one `with` calls)."
  # buf is a Janet buffer (GC-managed); :ptr marshals as pointer-to-data.
  # :free kept for the documented contract; :close is what Janet's
  # `with` actually calls :close (:free alone was NOT
  # with-compatible, measured 2026-10-04)
  {:ptr buf :n n :bytes (* n elem-bytes)
   :free (fn [_] nil) :close (fn [_] nil)})

#==------------------------------------------------------------------------==#
# vmap family (f64 first-class; i64/i32 core subset)
#==------------------------------------------------------------------------==#

(defn/typed vmap1 {:args [:keyword :struct] :ret :struct} [op h]
  "Elementwise unary map over a packed f64 handle; new handle out.
  Ops: :abs :neg :exp :log."
  (def n (check-h h 8 "vmap1"))
  (def out (new-out n))
  (jn_vmap1_f64 (check-op op :vmap1) (h :ptr) n out)
  (handle out n 8))

(defn/typed vmap2 {:args [:keyword :struct :struct] :ret :struct} [op a b]
  "Elementwise binary map over two equal-length packed f64 handles.
  Ops: :add :sub :mul :div :min :max."
  (def n (check-same-n a b))
  (check-h a 8 "vmap2")
  (check-h b 8 "vmap2")
  (def out (new-out n))
  (jn_vmap2_f64 (check-op op :vmap2) (a :ptr) (b :ptr) n out)
  (handle out n 8))

(defn/typed vmap1-scalar {:args [:keyword :struct :number] :ret :struct} [op h k]
  "Elementwise map of a packed f64 handle against scalar k. Ops:
  :add :sub :mul :div."
  (def n (check-h h 8 "vmap1-scalar"))
  (def out (new-out n))
  (jn_vmap1s_f64 (check-op op :vmap1s) (h :ptr) k n out)
  (handle out n 8))

(defn/typed vreduce {:args [:keyword :struct] :ret :number} [op h]
  "Reduce a packed f64 handle to a number. Ops: :sum :prod :min
  :max :sumsq. Accumulation is strictly sequential - bitwise
  agreement with a pure loop is the conformance bar."
  (check-h h 8 "vreduce")
  (jn_vreduce_f64 (check-red op :reduce) (h :ptr) (h :n)))

(defn/typed vscan {:args [:keyword :struct] :ret :struct} [op h]
  "Cumulative scan of a packed f64 handle - out element i folds
  elements 0 through i. Ops: :sum :prod :min :max (no :sumsq)."
  (def n (check-h h 8 "vscan"))
  (def out (new-out n))
  (jn_vscan_f64 (check-red op :scan) (h :ptr) n out)
  (handle out n 8))

(defn/typed vzip {:args [:struct :struct] :ret :struct} [a b]
  "Interleave two equal-length packed f64 handles elementwise into
  one 2n-element handle (a0 b0 a1 b1 ...)."
  (def n (check-same-n a b))
  (check-h a 8 "vzip")
  (check-h b 8 "vzip")
  (def out (new-out (* 2 n)))
  (jn_vzip_f64 (a :ptr) (b :ptr) n out)
  (handle out (* 2 n) 8))

(defn/typed vdot {:args [:struct :struct] :ret :number} [a b]
  "Dot product of two equal-length packed f64 handles."
  (def n (check-same-n a b))
  (check-h a 8 "vdot")
  (check-h b 8 "vdot")
  (jn_vdot_f64 (a :ptr) (b :ptr) n))

(defn/typed vaxpy {:args [:number :struct :struct] :ret :struct} [alpha x y]
  "Compute y := alpha*x + y IN PLACE in y's buffer (the one
  canonical in-place op) and return y. Equal lengths required."
  (def n (check-same-n x y))
  (check-h x 8 "vaxpy")
  (check-h y 8 "vaxpy")
  (jn_vaxpy_f64 alpha (x :ptr) (y :ptr) n)
  y)

#==------------------------------------------------------------------------==#
# slice 3: special-function vector kernels + matvec + row distances.
# CF/series forms follow the standard continued-fraction and series
# algorithms (Lentz, NR-style); erf/erfc/lgamma are libm. All take packed f64 handles (pack-f64).
#==------------------------------------------------------------------------==#

(defn/typed erf-v {:args [:struct] :ret :struct} [h]
  "Elementwise error function erf (libm) over a packed f64 handle;
  new handle out."
  (def n (check-h h 8 "erf-v"))
  (def out (new-out n))
  (jn_erf_f64 (h :ptr) n out)
  (handle out n 8))

(defn/typed erfc-v {:args [:struct] :ret :struct} [h]
  "Elementwise complementary error function erfc (libm) over a
  packed f64 handle; new handle out."
  (def n (check-h h 8 "erfc-v"))
  (def out (new-out n))
  (jn_erfc_f64 (h :ptr) n out)
  (handle out n 8))

(defn/typed lgamma-v {:args [:struct] :ret :struct} [h]
  "Elementwise log-gamma (reentrant lgamma_r) over a packed f64
  handle; new handle out."
  (def n (check-h h 8 "lgamma-v"))
  (def out (new-out n))
  (jn_lgamma_f64 (h :ptr) n out)
  (handle out n 8))

(defn/typed log-beta-v {:args [:struct :struct] :ret :struct} [a b]
  "Elementwise log Beta function over two equal-length packed f64
  handles; new handle out."
  (def n (check-same-n a b))
  (check-h a 8 "log-beta-v")
  (check-h b 8 "log-beta-v")
  (def out (new-out n))
  (jn_log_beta_f64 (a :ptr) (b :ptr) n out)
  (handle out n 8))

(defn/typed gamma-p-v {:args [:struct :struct] :ret :struct} [a x]
  "Elementwise regularised lower incomplete gamma P(a, x) over
  equal-length f64 handles. Domain a > 0, x >= 0 is caller-side."
  (def n (check-same-n a x))
  (check-h a 8 "gamma-p-v")
  (check-h x 8 "gamma-p-v")
  (def out (new-out n))
  (jn_gamma_p_f64 (a :ptr) (x :ptr) n out)
  (handle out n 8))

(defn/typed gamma-q-v {:args [:struct :struct] :ret :struct} [a x]
  "Elementwise regularised upper incomplete gamma Q(a, x) over
  equal-length f64 handles. Domain a > 0, x >= 0 is caller-side."
  (def n (check-same-n a x))
  (check-h a 8 "gamma-q-v")
  (check-h x 8 "gamma-q-v")
  (def out (new-out n))
  (jn_gamma_q_f64 (a :ptr) (x :ptr) n out)
  (handle out n 8))

(defn/typed beta-inc-v {:args [:struct :struct :struct] :ret :struct} [a b x]
  "Elementwise regularised incomplete beta I_x(a, b) over
  equal-length f64 handles. Domain a, b > 0 and 0 <= x <= 1 is
  caller-side."
  (def n (check-same-n a b))
  (check-same-n a x)
  (check-h a 8 "beta-inc-v")
  (check-h b 8 "beta-inc-v")
  (check-h x 8 "beta-inc-v")
  (def out (new-out n))
  (jn_beta_inc_f64 (a :ptr) (b :ptr) (x :ptr) n out)
  (handle out n 8))

(defn/typed pnorm-v {:args [:struct :number :number] :ret :struct} [h mean sd]
  "Elementwise normal CDF at the given mean and sd over a packed f64
  handle. sd must not be 0; a 0 sd errors wrapper-side."
  # fused erfc-route normal CDF
  (def n (check-h h 8 "pnorm-v"))
  (def out (new-out n))
  (jn_pnorm_f64 (h :ptr) mean sd n out)
  (handle out n 8))

(defn/typed ptukey-v {:args [:struct :number :number :number] :ret :struct} [h nmeans df nranges]
  "Elementwise studentised-range CDF PTUKEY(q, nmeans, df, nranges)
  over a packed f64 handle. Domain nmeans >= 2, df >= 2, nranges >= 1
  is caller-side (the stats layer validates). NaN in q is returned
  unchanged; NaN in any parameter yields a canonical NaN."
  # fused studentized-range CDF - mirrors the verified pure's
  # quadrature (kernel-abi section 4 for the domain + parity bar);
  # nranges explicit (R's rr; default 1 is caller-side)
  (def n (check-h h 8 "ptukey-v"))
  (def out (new-out n))
  (jn_ptukey_f64 (h :ptr) nmeans df nranges n out)
  (handle out n 8))

(defn/typed check-dims {:args [:struct :number :string] :ret :nil} [h want who]
  "Assert the handle's :n matches the explicitly passed dims -
  matrix lanes take dims on faith otherwise. Internal."
  # matrix lanes take EXPLICIT dims - they must match the handle
  (unless (= (h :n) want)
    (errorf "janet-num: %s handle holds %d elements, dims say %d"
            who (h :n) want)))

(defn/typed matvec {:args [:struct :struct :number :number] :ret :struct} [m v n p]
  "Row-major n x p matrix (packed f64) times a p-vector; out is a
  packed n-vector handle."
  # m: row-major n x p packed handle; v: p-vector handle
  (check-h m 8 "matvec")
  (check-h v 8 "matvec")
  (check-dims m (* n p) "matvec m")
  (check-dims v p "matvec v")
  (def out (new-out n))
  (jn_matvec_f64 (m :ptr) (v :ptr) n p out)
  (handle out n 8))

(defn/typed dist2-rows {:args [:struct :struct :number :number :number] :ret :struct} [x c n p k]
  "Squared euclidean distances from each of n p-dimensional points
  (x, row-major n x p) to each of k centers (c, k x p); out is n x k
  row-major."
  # x: n x p points; c: k x p centers -> n x k squared distances
  (check-h x 8 "dist2-rows")
  (check-h c 8 "dist2-rows")
  (check-dims x (* n p) "dist2-rows x")
  (check-dims c (* k p) "dist2-rows c")
  (def out (new-out (* n k)))
  (jn_dist2_rows_f64 (x :ptr) (c :ptr) n p k out)
  (handle out (* n k) 8))

#==------------------------------------------------------------------------==#
# slice 3.5 (linalg tier): row-major matrix kernels. chol-solve and
# lu-solve write IN PLACE into b; lu-solve stages an n*n scratch
# buffer here (the never-allocate policy)
#==------------------------------------------------------------------------==#

(defn/typed matmul {:args [:struct :struct :number :number :number] :ret :struct} [a b m k n]
  "Row-major m x k matrix times k x n matrix; out is m x n
  row-major."
  # a: m x k; b: k x n; -> m x n (row-major)
  (check-h a 8 "matmul")
  (check-h b 8 "matmul")
  (check-dims a (* m k) "matmul a")
  (check-dims b (* k n) "matmul b")
  (def out (new-out (* m n)))
  (jn_matmul_f64 (a :ptr) (b :ptr) m k n out)
  (handle out (* m n) 8))

(defn/typed cholesky-l {:args [:struct :number] :ret :tuple} [a n]
  "Lower Cholesky factor of an n x n symmetric positive-definite
  matrix (input copied, never touched). Returns [status L-handle];
  status 1 ok, 0 not SPD (non-positive diagonal)."
  # a: n x n SPD (row-major, copied) -> [status lower-L-handle n*n]
  (check-h a 8 "cholesky-l")
  (check-dims a (* n n) "cholesky-l")
  (def out (new-out (* n n)))
  (def status (jn_cholesky_f64 (a :ptr) n out))
  [status (handle out (* n n) 8)])

(defn/typed chol-solve {:args [:struct :struct :number] :ret :number} [l b n]
  "Solve L L' x = b for lower-triangular L (nonzero diagonal),
  writing x IN PLACE into b's buffer. Returns status: 1 ok,
  0 failure."
  # solves L L' x = b IN PLACE in b; returns status
  (check-h l 8 "chol-solve")
  (check-h b 8 "chol-solve")
  (check-dims l (* n n) "chol-solve l")
  (check-dims b n "chol-solve b")
  (jn_chol_solve_f64 (l :ptr) (b :ptr) n))

(defn/typed lu-solve {:args [:struct :struct :number] :ret :number} [a b n]
  "LU partial-pivot factor and solve of an n x n system, writing x
  IN PLACE into b's buffer. Returns status: 1 ok, 0 near-singular
  (pivot < 1e-300)."
  # LU partial-pivot factor+solve, x written IN PLACE into b
  (check-h a 8 "lu-solve")
  (check-h b 8 "lu-solve")
  (check-dims a (* n n) "lu-solve a")
  (check-dims b n "lu-solve b")
  (def work (new-out (* n n)))
  (jn_lu_solve_f64 (a :ptr) (b :ptr) n work))

# i64 / i32 variants (core subset per requirements-slice2.md)
(defn/typed vmap2-i64 {:args [:keyword :struct :struct] :ret :struct} [op a b]
  "Elementwise i64 map over two equal-length packed handles. Ops:
  :add :sub :mul :min :max. Arithmetic runs unsigned internally -
  wraparound is defined two's-complement behaviour, never UB."
  (def n (check-same-n a b))
  (check-h a 8 "vmap2-i64")
  (check-h b 8 "vmap2-i64")
  (def out (new-out n))
  (jn_vmap2_i64 (check-op op :vmap2i) (a :ptr) (b :ptr) n out)
  (handle out n 8))

(defn/typed vmap1s-i64 {:args [:keyword :struct :any] :ret :struct} [op h k]
  "Elementwise i64 map of a packed handle against scalar k. Ops:
  :add :sub :mul :div."
  (def n (check-h h 8 "vmap1s-i64"))
  (def out (new-out n))
  (jn_vmap1s_i64 (check-op op :vmap1s) (h :ptr) k n out)
  (handle out n 8))

(defn/typed vreduce-i64 {:args [:keyword :struct] :ret :any} [op h]
  "Reduce a packed i64 handle to an int64 box. Ops: :sum :min
  :max."
  (check-h h 8 "vreduce-i64")
  (jn_vreduce_i64 (check-red op :reduce64) (h :ptr) (h :n)))

(defn/typed vscan-i64 {:args [:keyword :struct] :ret :struct} [op h]
  "Cumulative scan of a packed i64 handle. Ops: :sum :min :max."
  (def n (check-h h 8 "vscan-i64"))
  (def out (new-out n))
  (jn_vscan_i64 (check-red op :scan64) (h :ptr) n out)
  (handle out n 8))

(defn/typed vmap2-i32 {:args [:keyword :struct :struct] :ret :struct} [op a b]
  "Elementwise i32 map over two equal-length packed 4-byte handles.
  Ops: :add :sub :mul :min :max."
  (def n (check-same-n a b))
  (check-h a 4 "vmap2-i32")
  (check-h b 4 "vmap2-i32")
  (def out (buffer/new-filled (* 4 n) 0))
  (jn_vmap2_i32 (check-op op :vmap2i) (a :ptr) (b :ptr) n out)
  (handle out n 4))

(defn/typed vreduce-i32 {:args [:keyword :struct] :ret :any} [op h]
  "Reduce a packed i32 handle. Ops: :sum :min :max."
  (check-h h 4 "vreduce-i32")
  (jn_vreduce_i32 (check-red op :reduce64) (h :ptr) (h :n)))

(defn/typed vscan-i32 {:args [:keyword :struct] :ret :struct} [op h]
  "Cumulative scan of a packed i32 handle. Ops: :sum :min :max."
  (def n (check-h h 4 "vscan-i32"))
  (def out (buffer/new-filled (* 4 n) 0))
  (jn_vscan_i32 (check-red op :scan64) (h :ptr) n out)
  (handle out n 4))

(defn/typed interleave-chunk-f32 {:args [:any :any :number :number :number :any] :ret nil} [cols-table masks-table ncol nrow row-offset out]
  "C-to-C lane: raw column pointer tables plus validity bitmaps to
  f32 rows at row-offset; NULL/invalid entries become NaN. For
  engine modules holding raw buffers - the caller owns all memory."
  # C-to-C path for engine modules holding raw column buffers (e.g.
  # database chunk vectors): pointer tables + validity bitmaps -> f32
  # rows at row-offset. NULL/invalid -> NaN. Caller owns all memory.
  (jn_interleave_f32_null cols-table masks-table ncol nrow row-offset out))

(defn/typed version {:args [] :ret :string} []
  "Kernel library version string; asserted by the smoke, so every
  release bumps it."
  (jn_version))

(defn/typed check-columns {:args [:any] :ret :tuple} [cols]
  "Validate a non-empty table of equal-length column arrays; returns
  [ncol nrow]. Internal."
  (def ncol (length cols))
  (when (or (not ncol) (zero? ncol)) (error "janet-num: no columns"))
  (def nrow (length (cols 0)))
  (each c cols (unless (= (length c) nrow)
                 (errorf "janet-num: ragged columns (expected %d rows)" nrow)))
  [ncol nrow])

(defn/typed pack-columns-f32 {:args [:any] :ret :struct} [cols]
  "Column-major double arrays to a row-major f32 packed handle
  {:nrow :ncol}; one transposing C pass over shared staging."
  # column-major double arrays -> row-major f32 packed buffer.
  # Staging: ONE shared buffer, each column written at byte offset -
  # fresh per-column buffers measured 7x slower (allocation churn,
  # 61 vs 9 ns/elem).
  (def [ncol nrow] (check-columns cols))
  (def staging (buffer/new-filled (* 8 ncol nrow) 0))
  (for c 0 ncol
    (ffi/write @[:double nrow] (cols c) staging (* c nrow 8)))
  (def out (buffer/new-filled (* 4 nrow ncol) 0))
  (jn_interleave_f32 staging ncol nrow out)
  {:ptr out :n (* nrow ncol) :bytes (* 4 nrow ncol)
   :nrow nrow :ncol ncol :free (fn [_] nil) :close (fn [_] nil)})

(defn/typed pack-columns-f64 {:args [:any] :ret :struct} [cols]
  "Column-major double arrays to a row-major f64 packed handle
  {:nrow :ncol}; one transposing C pass over shared staging."
  # column-major double arrays -> row-major f64 packed buffer
  # (same shared-staging shape as pack-columns-f32)
  (def [ncol nrow] (check-columns cols))
  (def staging (buffer/new-filled (* 8 ncol nrow) 0))
  (for c 0 ncol
    (ffi/write @[:double nrow] (cols c) staging (* c nrow 8)))
  (def out (buffer/new-filled (* 8 nrow ncol) 0))
  (jn_interleave_f64 staging ncol nrow out)
  {:ptr out :n (* nrow ncol) :bytes (* 8 nrow ncol)
   :nrow nrow :ncol ncol :free (fn [_] nil) :close (fn [_] nil)})

(defn/typed unpack-columns-f32 {:args [:struct] :ret :array} [packed]
  "Row-major f32 packed handle (needs :nrow :ncol) to an array of
  double column arrays."
  # row-major f32 packed buffer -> array of double arrays
  (def in (packed :ptr))
  (def nrow (packed :nrow))
  (def ncol (packed :ncol))
  (def bufs (seq [_ :range [0 ncol]] (buffer/new-filled (* 8 nrow) 0)))
  (def cols-ptr (ffi/write @[:ptr ncol] bufs))
  (jn_deinterleave_f32 in ncol nrow cols-ptr)
  (seq [b :in bufs] (ffi/read @[:double nrow] b)))

(defn/typed unpack-columns-f64 {:args [:struct] :ret :array} [packed]
  "Row-major f64 packed handle (needs :nrow :ncol) to an array of
  double column arrays."
  # row-major f64 packed buffer -> array of double arrays
  (def in (packed :ptr))
  (def nrow (packed :nrow))
  (def ncol (packed :ncol))
  (def bufs (seq [_ :range [0 ncol]] (buffer/new-filled (* 8 nrow) 0)))
  (def cols-ptr (ffi/write @[:ptr ncol] bufs))
  (jn_deinterleave_f64 in ncol nrow cols-ptr)
  (seq [b :in bufs] (ffi/read @[:double nrow] b)))

#==------------------------------------------------------------------------==#
# Integer/bitset tier (flat u64 buffers - bit-vector word size)
#==------------------------------------------------------------------------==#

(defn/typed pack-u64 {:args [:any] :ret :struct} [xs]
  "Flat array of u64/s64 boxes or non-negative integers to a packed
  u64 handle. Boxes write bit-exact; plain doubles cap at 2^53.
  String elements are rejected - parse via (int/u64 \"...\") first."
  # flat Janet array of u64 boxes / non-negative integers -> packed
  # uint64 buffer. s64/u64 boxes write BIT-EXACT (two's complement
  # reinterpretation - pack negative words as s64 boxes); ffi/write
  # validates natively, and its plain-double band is [0, 2^53]
  # (above that doubles are imprecise - use string boxes). String
  # elements are rejected wrapper-side: the primitive would parse
  # them silently.
  (def n (length xs))
  (when (zero? n) (error "janet-num: empty u64 array"))
  (each x xs
    (when (bytes? x)
      (errorf "janet-num: pack-u64 needs u64/s64 boxes or non-negative integers, got %q - parse strings via (int/u64 \"...\") first" x)))
  (handle (ffi/write @[:uint64 n] xs) n 8))

(defn/typed pack-i64 {:args [:any] :ret :struct} [xs]
  "Flat array of s64/u64 boxes or integers in [-2^53, 2^53] to a
  packed i64 handle; boxes write bit-exact. String elements are
  rejected - parse via (int/s64 \"...\") first."
  # flat Janet array of s64/u64 boxes or integers -> packed int64
  # buffer. ffi/write handles every element type natively (boxes
  # write BIT-EXACT; plain doubles cap at the [-2^53, 2^53] band -
  # beyond that the READER has already made imprecise doubles). String
  # elements are rejected wrapper-side: the primitive would parse
  # them silently.
  (def n (length xs))
  (when (zero? n) (error "janet-num: empty i64 array"))
  (each x xs
    (when (bytes? x)
      (errorf "janet-num: pack-i64 needs s64/u64 boxes or integers in [-2^53, 2^53], got %q - parse strings via (int/s64 \"...\") first" x)))
  (handle (ffi/write @[:int64 n] xs) n 8))

(defn/typed unpack-u64 {:args [:struct] :ret :array} [packed]
  "Packed u64 handle to an array of int/u64 boxes; they compare by
  identity - use (string (int/s64 box)) on both sides for exact
  comparison."
  # packed uint64 buffer -> array of u64 boxes
  (ffi/read @[:uint64 (packed :n)] (packed :ptr)))

(defn/typed pack-f64 {:args [:any] :ret :struct} [xs]
  "Flat array of numbers to a packed f64 handle - the currency of
  the vmap and matrix families."
  # flat Janet array of numbers -> packed double buffer (the vmap
  # family's currency; handles-only, no transparent array sugar).
  # ffi/write validates elements natively (the error names the index
  # and value) - a Janet-side loop would only duplicate it.
  (def n (length xs))
  (when (zero? n) (error "janet-num: empty f64 array"))
  (handle (ffi/write @[:double n] xs) n 8))

(defn/typed unpack-f64 {:args [:struct] :ret :array} [packed]
  "Packed f64 handle to an array of numbers."
  # packed double buffer -> array of numbers
  (ffi/read @[:double (packed :n)] (packed :ptr)))

(defn/typed pack-i32 {:args [:any] :ret :struct} [xs]
  "Flat array of integers to a packed i32 handle; integrality and
  range are checked natively, never silently wrapped."
  # flat Janet array of small integers -> packed int32 buffer.
  # ffi/write checks integrality and int32 range natively
  # (out-of-range and fractional values error, never silently wrap).
  (def n (length xs))
  (when (zero? n) (error "janet-num: empty i32 array"))
  (handle (ffi/write @[:int32 n] xs) n 4))

(defn/typed unpack-i32 {:args [:struct] :ret :array} [packed]
  "Packed i32 handle to an array of numbers."
  # packed int32 buffer -> array of numbers
  (ffi/read @[:int32 (packed :n)] (packed :ptr)))

(defn/typed u64-binop {:args [:struct :struct :any :string] :ret :struct} [a b kernel who]
  "Shared elementwise u64 path: length and width checks, out buffer,
  kernel call. Internal."
  # shared elementwise path: length + width checks, out buffer, call
  (def n (check-same-n a b))
  (check-h a 8 who)
  (check-h b 8 who)
  (def out (buffer/new-filled (* 8 n) 0))
  (kernel (a :ptr) (b :ptr) n out)
  (handle out n 8))

(defn/typed band {:args [:struct :struct] :ret :struct} [a b]
  "Bitwise and of two equal-length packed u64 handles; new handle
  out. Shadows core band under a :prefix \"\" import - capture the
  core fn first if you need both."
  (u64-binop a b jn_band_u64 "band"))

(defn/typed bor {:args [:struct :struct] :ret :struct} [a b]
  "Bitwise or of two equal-length packed u64 handles; new handle
  out. Shadows core bor under a :prefix \"\" import."
  (u64-binop a b jn_bor_u64 "bor"))

(defn/typed bxor {:args [:struct :struct] :ret :struct} [a b]
  "Bitwise exclusive or of two equal-length packed u64 handles; new
  handle out. Shadows core bxor under a :prefix \"\" import."
  (u64-binop a b jn_bxor_u64 "bxor"))

(defn/typed popcount {:args [:struct] :ret :struct} [a]
  "Population count of every word of a packed u64 handle into a new
  packed u64 handle."
  # per-word population counts into a new packed u64 buffer
  (def n (check-h a 8 "popcount"))
  (def out (buffer/new-filled (* 8 n) 0))
  (jn_popcount_u64 (a :ptr) n out)
  (handle out n 8))

#==------------------------------------------------------------------------==#
# Packed-buffer readers (no unpack: scalar/vector views over the buffer)
#==------------------------------------------------------------------------==#

(defn/typed packed-slice-f32 {:args [:struct :number] :ret :any} [packed n]
  "First n f32 elements of a packed column buffer as an array of
  widened doubles, capped at nrow x ncol."
  # first n f32 elements of the packed buffer, widened to doubles
  (ffi/read @[:float (min n (* (packed :nrow) (packed :ncol)))] (packed :ptr)))

(defn/typed packed-slice-f64 {:args [:struct :number] :ret :any} [packed n]
  "First n f64 elements of a packed column buffer as an array of
  doubles, capped at nrow x ncol."
  (ffi/read @[:double (min n (* (packed :nrow) (packed :ncol)))] (packed :ptr)))
