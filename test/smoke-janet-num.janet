# smoke-janet-num - conformance for the pack/unpack kernels.
# Pure-Janet loops are the oracle (bitwise for f64 paths; the f32
# section casts via Janet's own number semantics). Requires libjn;
# skips cleanly when absent.
(import ../janet-num)
(import typed :prefix "")

(defn assert-eq [a b msg]
  (unless (deep= a b) (errorf "FAIL %s: %q != %q" msg a b)))

(defn assert-raises [f msg-match]
  (var caught nil)
  (try (f) ([e] (set caught e)))
  (unless (and caught (string/find msg-match caught))
    (errorf "FAIL expected error matching %q, got %q" msg-match caught)))

# deterministic LCG (exact in doubles: products < 2^53)
(defn lcg-next [x] (mod (+ (* x 1103515245) 12345) 2147483648))
(defn lcg-cols [ncol nrow]
  (def cols @[])
  (var s 42)
  (for c 0 ncol
    (def col (array/new nrow))
    (for r 0 nrow
      (set s (lcg-next s))
      (array/push col (- (* 100 (/ s 2147483648.0)) 50)))
    (array/push cols col))
  cols)

# -- version ------------------------------------------------------------------
(assert (string/find "0.1.0" (janet-num/version)) "version string")

# -- hand-checked interleave ---------------------------------------------------
(def small [@[1.5 2.5 3.5] @[10.25 20.5 30.75]])
(def p32 (janet-num/pack-columns-f32 small))
(assert-eq [(p32 :nrow) (p32 :ncol) (p32 :bytes)] [3 2 24] "f32 handle shape")
(assert-eq (janet-num/packed-slice-f32 p32 6) @[1.5 10.25 2.5 20.5 3.5 30.75] "f32 interleave")
(assert-eq (janet-num/unpack-columns-f32 p32) (seq [c :in small] (array/slice c))
  "f32 round trip (exact values)")
(def p64 (janet-num/pack-columns-f64 small))
(assert-eq (janet-num/packed-slice-f64 p64 6) @[1.5 10.25 2.5 20.5 3.5 30.75] "f64 interleave")
(assert-eq (janet-num/unpack-columns-f64 p64) (seq [c :in small] (array/slice c))
  "f64 round trip")
(:free p32)
(:free p32) # idempotent
(:free p64)

# -- LCG fixtures vs pure-Janet loops (f64, bitwise) -----------------------------
(def NCOL 8)
(def NROW 10000)
(def cols (lcg-cols NCOL NROW))
(def expected-flat (array/new (* NCOL NROW)))
(for r 0 NROW
  (for c 0 NCOL (array/push expected-flat (get (get cols c) r))))
(def big64 (janet-num/pack-columns-f64 cols))
(assert-eq (janet-num/packed-slice-f64 big64 (* NCOL NROW)) expected-flat
  "kernel f64 interleave == pure-Janet loop (bitwise, 80k elems)")
(assert-eq (janet-num/unpack-columns-f64 big64) cols "f64 unpack == original (bitwise)")
(:free big64)

# -- f32 conversion vs pure-Janet exact-integer oracle ------------------------
# LCG fixtures are dyadic rationals k/2^31 (k integer, exact in doubles),
# so f32 rounding is exactly simulable in integer arithmetic: shift k to
# 24 significant bits, round-half-EVEN, scale back.
# (a database ::FLOAT cast was tried as oracle and REJECTED: it deviates from
# IEEE round-half-even on exact ties - found by this very fixture,
# k mod 4096 = 2048 on elem 13; the kernel matches hardware.)
(defn/typed bitlen {:args [:number] :ret :number} [n]
  (var b 0)
  (var m n)
  (while (> m 0) (set m (div m 2)) (++ b))
  b)

(defn/typed f32-of-dyadic {:args [:number] :ret :number} [k]
  # exact f32 value of k/2^31 as a double (k integer-valued, may be neg)
  (if (zero? k) 0
    (let [neg (neg? k)
          a (if neg (- k) k)
          sh (max 0 (- (bitlen a) 24))]
      (if (<= sh 0) (/ k 2147483648.0)
        (let [p2sh (math/pow 2 sh)
              half (/ p2sh 2)
              q (div a p2sh)
              rem (mod a p2sh)
              q2 (cond (> rem half) (inc q)
                       (< rem half) q
                       (odd? q) (inc q) # tie -> round to even
                       q)
              mag (/ q2 (math/pow 2 (- 31 sh)))]
          (if neg (- mag) mag))))))

(def probe-n 1000)
(def probe-col (slice (cols 0) 0 probe-n))
(def k32 (janet-num/pack-columns-f32 [probe-col]))
(def kernel-f32 (janet-num/packed-slice-f32 k32 probe-n))
(for i 0 probe-n
  (def v (probe-col i))
  (assert-eq (f32-of-dyadic (* v 2147483648)) (kernel-f32 i)
    (string "f32 exact-integer oracle, elem " i)))
(:free k32)

# -- error paths ------------------------------------------------------------------
(assert-raises (fn [] (janet-num/pack-columns-f32 [])) "no columns")
(assert-raises (fn [] (janet-num/pack-columns-f32 [@[1 2] @[1 2 3]])) "ragged")
(assert-raises (fn [] (janet-num/pack-columns-f64 [@[1 2] @[1 2 3]])) "ragged")

# -- regressions (2026-10-04): width, op-set, with, packers ----------
(def bad-w (janet-num/pack-i32 @[1 2 3 4]))
(assert-raises (fn [] (janet-num/vmap2-i64 :add bad-w bad-w)) "8-byte")
(assert-raises (fn [] (janet-num/vmap2 :add bad-w bad-w)) "8-byte")
(assert-raises (fn [] (janet-num/vreduce-i64 :sum bad-w)) "8-byte")
(def h-ok (janet-num/pack-f64 @[1.0 2.0]))
(assert-raises (fn [] (janet-num/vscan :sumsq h-ok)) ":sumsq")
(assert-raises (fn [] (janet-num/vmap1-scalar :abs h-ok 0)) ":abs")
(assert-raises (fn [] (janet-num/vmap1 :add h-ok)) ":add")
(assert-eq (with [h (janet-num/pack-f64 @[1.0 2.0])]
             (janet-num/unpack-f64 (janet-num/vmap1 :abs h)))
           @[1.0 2.0] "with works (:close)")
(assert-raises (fn [] (janet-num/pack-f64 @[1 nil 3])) "number")
(assert-raises (fn [] (janet-num/pack-u64 @[-1])) "can not convert number -1")
(assert-raises (fn [] (janet-num/pack-i32 @[1.5])) "integer")
(def h-i64 (janet-num/pack-i64 @[(int/s64 -1) 2]))
(assert-eq (map string (janet-num/unpack-u64 h-i64))
           @["18446744073709551615" "2"] "pack-i64 bit-exact via u64 view")

# -- packer element validation (2026-10-05): the primitives check
# natively (ffi/write for f64/i32/u64, the :int64 conversion for i64);
# native errors name the element index and the offending value. The
# i64/u64 packers reject string elements wrapper-side (the primitives
# would parse them silently, including hex); buffer inputs are
# rejected by ffi/write's array-or-tuple check.
(assert-raises (fn [] (janet-num/pack-f64 @[1.5 "x" 2.5])) "bad slot #1, expected number")
(assert-raises (fn [] (janet-num/pack-f64 @[(int/s64 5) 1.5])) "expected number")
(assert-raises (fn [] (janet-num/pack-f64 @"abc")) "expected array or tuple")
(assert-raises (fn [] (janet-num/pack-i32 @[1 1.5])) "expected 32 bit signed integer")
(assert-raises (fn [] (janet-num/pack-i32 @[1 3500000000])) "expected 32 bit signed integer")
(assert-raises (fn [] (janet-num/pack-i32 @[1 -2147483649])) "expected 32 bit signed integer")
(assert-raises (fn [] (janet-num/pack-i32 @[(int/s64 5)])) "expected 32 bit signed integer")
(assert-raises (fn [] (janet-num/pack-i32 @"abc")) "expected array or tuple")
(assert-raises (fn [] (janet-num/pack-i64 @[1 1.5])) "can not convert number 1.5")
(assert-raises (fn [] (janet-num/pack-i64 @[1 1e17])) "can not convert number")
(assert-raises (fn [] (janet-num/pack-i64 @["x"])) "pack-i64 needs")
(assert-raises (fn [] (janet-num/pack-i64 @["-5"])) "pack-i64 needs")
(assert-raises (fn [] (janet-num/pack-i64 @[(buffer "a")])) "pack-i64 needs")
(assert-raises (fn [] (janet-num/pack-i64 @[1 9007199254740994])) "can not convert number")
(assert-eq (map string (janet-num/unpack-u64 (janet-num/pack-i64 @[9007199254740992 -9007199254740992])))
           @["9007199254740992" "18437736874454810624"] "pack-i64 band edges inclusive (u64 view)")
(assert-raises (fn [] (janet-num/pack-i64 @[])) "empty")
(assert-raises (fn [] (janet-num/pack-i64 @"ab")) "expected array or tuple")
(assert-eq (map string (janet-num/unpack-u64 (janet-num/pack-i64 @[(int/u64 "9223372036854775808")])))
           @["9223372036854775808"] "pack-i64 u64 box high bit bit-exact")

# -- pack-u64: same native delegation plus the string guard
(assert-raises (fn [] (janet-num/pack-u64 @[1 "x"])) "pack-u64 needs")
(assert-raises (fn [] (janet-num/pack-u64 @["123"])) "pack-u64 needs")
(assert-raises (fn [] (janet-num/pack-u64 @["0x10"])) "pack-u64 needs")
(assert-raises (fn [] (janet-num/pack-u64 @[1 1.5])) "can not convert number 1.5")
(assert-raises (fn [] (janet-num/pack-u64 @[1 1e17])) "can not convert number")
(assert-raises (fn [] (janet-num/pack-u64 @[1 18446744073709551616])) "can not convert number")
(assert-raises (fn [] (janet-num/pack-u64 @"ab")) "expected array or tuple")
(assert-eq (map string (janet-num/unpack-u64 (janet-num/pack-u64 @[(int/s64 -1) (int/u64 "18446744073709551615")])))
           @["18446744073709551615" "18446744073709551615"] "pack-u64 boxes bit-exact")
(assert-eq (map string (janet-num/unpack-u64 (janet-num/pack-u64 @[9007199254740992])))
           @["9007199254740992"] "pack-u64 double band edge 2^53")
(assert-raises (fn [] (janet-num/pack-u64 @[])) "empty")

# -- packed-slice bounds ------------------------------------------------------------
(def p (janet-num/pack-columns-f64 [@[1 2 3]]))
(assert-eq (janet-num/packed-slice-f64 p 100) @[1 2 3] "slice clamps to buffer")
(:free p)

# -- integer/bitset kernels vs Janet boxed-op oracle --------------------------
# random u64 words as 16-hex-digit strings (exact); Janet's own band/bor/
# bxor on int/u64 boxes are the oracle (independent implementation);
# popcount vs a pure-Janet per-bit loop.
(def W 64)
(def words-a @[])
(def words-b @[])
(var sa 42)
(var sb 7)
(for _ 0 W
  (set sa (lcg-next sa))
  (set sb (lcg-next sb))
  (array/push words-a (int/u64 (string "0x" (string/format "%08x%08x" sa sb))))
  (array/push words-b (int/u64 (string "0x" (string/format "%08x%08x" sb sa)))))

(def pa (janet-num/pack-u64 words-a))
(def pb (janet-num/pack-u64 words-b))

# pack/unpack round trip (string compare - u64 boxes may exceed 2^53)
(assert-eq (map string (janet-num/unpack-u64 pa)) (map string words-a)
  "u64 pack/unpack round trip (64 words)")
(assert-eq (map string (janet-num/unpack-u64 pb)) (map string words-b)
  "u64 round trip b")

# band/bor/bxor vs boxed-op oracle
(def k-band (janet-num/band pa pb))
(def k-bor (janet-num/bor pa pb))
(def k-bxor (janet-num/bxor pa pb))
(def o-band (map string (janet-num/unpack-u64 k-band)))
(def o-bor (map string (janet-num/unpack-u64 k-bor)))
(def o-bxor (map string (janet-num/unpack-u64 k-bxor)))
(for i 0 W
  (assert-eq (o-band i) (string (band (words-a i) (words-b i)))
    (string "band oracle, word " i))
  (assert-eq (o-bor i) (string (bor (words-a i) (words-b i)))
    (string "bor oracle, word " i))
  (assert-eq (o-bxor i) (string (bxor (words-a i) (words-b i)))
    (string "bxor oracle, word " i)))

# popcount vs pure-Janet per-bit loop
(defn popcount-box [w]
  (var cnt 0)
  (for i 0 64
    (def bit (int/to-number (band (brshift w i) (int/u64 "1"))))
    (when (= bit 1) (++ cnt)))
  cnt)
(def pop-out (map string (janet-num/unpack-u64 (janet-num/popcount pa))))
(for i 0 W
  (assert-eq (pop-out i) (string (popcount-box (words-a i)))
    (string "popcount oracle, word " i)))

# mixed input: plain small numbers alongside boxes
(def pmixed (janet-num/pack-u64 @[(int/u64 "0xF0F0") 1 2 3]))
(assert-eq (map string (janet-num/unpack-u64 pmixed))
           @["61680" "1" "2" "3"] "u64 mixed box/number packing")

# -- slice 2: vmap family vs pure-Janet oracles (bitwise) ---------------------
# fixtures reuse the LCG columns (in scope above); both sides accumulate
# sequentially, so equality is bitwise by construction
(def VN 5000)
(def va (slice (cols 0) 0 VN))
(def vb (slice (cols 1) 0 VN))
(def ha (janet-num/pack-f64 va))
(def hb (janet-num/pack-f64 vb))

(defn oracle2 [f] (seq [i :range [0 VN]] (f (va i) (vb i))))
(defn oracle1 [f] (seq [i :range [0 VN]] (f (va i))))

(each [op f] [[:add +] [:sub -] [:mul *] [:div /]
              [:min (fn [x y] (if (< x y) x y))]
              [:max (fn [x y] (if (> x y) x y))]]
  (assert-eq (janet-num/unpack-f64 (janet-num/vmap2 op ha hb))
             (oracle2 f) (string "vmap2 " op " oracle")))
(each [op f] [[:abs math/abs] [:neg -]]
  (assert-eq (janet-num/unpack-f64 (janet-num/vmap1 op ha))
             (oracle1 f) (string "vmap1 " op " oracle")))
# exp/log (0.5.0): in-domain fixture - log of ha's negative members is
# NaN with a SIGN-of-payload mismatch (libm nan vs Janet -nan); the
# out-of-domain NaN contract is asserted in the conformance suite
# (NaN is NaN there), not bitwise here
(def hpos (janet-num/pack-f64 (map |(+ 0.5 (* 0.031 $)) (range 128))))
(each [op f] [[:exp math/exp] [:log math/log]]
  (assert-eq (janet-num/unpack-f64 (janet-num/vmap1 op hpos))
             (map f (janet-num/unpack-f64 hpos))
             (string "vmap1 " op " oracle")))
(each [op k f] [[:add 3.25 (fn [x] (+ x 3.25))] [:mul -0.5 (fn [x] (* x -0.5))]]
  (assert-eq (janet-num/unpack-f64 (janet-num/vmap1-scalar op ha k))
             (oracle1 f) (string "vmap1-scalar " op " oracle")))

(var o-sum 0) (var o-sumsq 0)
(each x va (+= o-sum x) (+= o-sumsq (* x x)))
(assert-eq (janet-num/vreduce :sum ha) o-sum "vreduce sum oracle")
(assert-eq (janet-num/vreduce :sumsq ha) o-sumsq "vreduce sumsq oracle")
(assert-eq (janet-num/vreduce :min ha) (min ;va) "vreduce min oracle")
(assert-eq (janet-num/vreduce :max ha) (max ;va) "vreduce max oracle")
(def small10 (janet-num/pack-f64 @[1.5 -2 0.5 3 -1 2 0.25 4 1 0.5]))
(var o-prod 1) (each x (janet-num/unpack-f64 small10) (*= o-prod x))
(assert-eq (janet-num/vreduce :prod small10) o-prod "vreduce prod oracle (10 elems)")

(var o-scan 0)
(def o-scan-out (seq [x :in va] (do (+= o-scan x) o-scan)))
(assert-eq (janet-num/unpack-f64 (janet-num/vscan :sum ha))
           o-scan-out "vscan sum oracle")
(var o-smin math/inf)
(def o-smin-out (seq [x :in va] (do (if (< x o-smin) (set o-smin x)) o-smin)))
(assert-eq (janet-num/unpack-f64 (janet-num/vscan :min ha))
           o-smin-out "vscan min oracle")

(def o-zip-flat (mapcat (fn [i] [(va i) (vb i)]) (range VN)))
(assert-eq (janet-num/unpack-f64 (janet-num/vzip ha hb))
           o-zip-flat "vzip oracle")
(var o-dot 0)
(for i 0 VN (+= o-dot (* (va i) (vb i))))
(assert-eq (janet-num/vdot ha hb) o-dot "vdot oracle")

(def hy (janet-num/pack-f64 (seq [_ :range [0 VN]] 1.5)))
(assert-eq (janet-num/unpack-f64 (janet-num/vaxpy 0.25 ha hy))
           (oracle1 (fn [x] (+ 1.5 (* 0.25 x)))) "vaxpy oracle")

# i64: reuse the u64 word fixtures; Janet boxed +/-/* are the oracle
# (both wrap two's-complement)
(def ia (janet-num/pack-u64 words-a))
(def ib (janet-num/pack-u64 words-b))
(assert-eq (map string (janet-num/unpack-u64 (janet-num/vmap2-i64 :add ia ib)))
           (map (fn [i] (string (+ (words-a i) (words-b i)))) (range W))
  "vmap2-i64 add oracle")
(assert-eq (map string (janet-num/unpack-u64 (janet-num/vmap2-i64 :sub ia ib)))
           (map (fn [i] (string (- (words-a i) (words-b i)))) (range W))
  "vmap2-i64 sub oracle")
(var o-i64sum (words-a 0))
(for i 1 W (set o-i64sum (+ o-i64sum (words-a i))))
(assert-eq (string (janet-num/vreduce-i64 :sum ia))
           (string o-i64sum)
  "vreduce-i64 sum oracle")
(assert-eq (map string (janet-num/unpack-u64 (janet-num/vscan-i64 :sum ia)))
           (let [acc @[(words-a 0)]]
             (for i 1 W (array/push acc (+ (acc (dec i)) (words-a i))))
             (map string acc))
  "vscan-i64 sum oracle")

# i32
(def i32a (janet-num/pack-i32 @[10 -20 30 40]))
(def i32b (janet-num/pack-i32 @[1 2 -3 4]))
(assert-eq (janet-num/unpack-i32 (janet-num/vmap2-i32 :mul i32a i32b))
           @[10 -40 -90 160] "vmap2-i32 mul oracle")
(assert-eq (int/to-number (janet-num/vreduce-i32 :sum i32a)) 60 "vreduce-i32 sum oracle")
(assert-eq (janet-num/unpack-i32 (janet-num/vscan-i32 :sum i32a))
           @[10 -10 20 60] "vscan-i32 sum oracle")

# error paths
(assert-raises (fn [] (janet-num/vmap2 :quux ha hb)) "does not implement")
(assert-raises (fn [] (janet-num/vreduce :quux ha)) "does not implement")
(assert-raises (fn [] (janet-num/vmap2 :add ha (janet-num/pack-f64 @[1 2]))) "differ in length")
(assert-raises (fn [] (janet-num/pack-f64 @[])) "empty")
(assert-raises (fn [] (janet-num/pack-i32 @[])) "empty")
(assert-raises (fn [] (janet-num/band pa pmixed)) "differ in length")
(assert-raises (fn [] (janet-num/pack-u64 @[])) "empty")

# -- ptukey kernel (1.1.0): R-pinned spots + the poles ------------------------
# The studentized-range CDF. Expected values are R's ptukey() at %.17g
# (the R-fixture grid); the tolerance is the specfun parity bar.
(each [q k df rr want]
  [[0.5 2 10 1 0.26898618932459484]
   [2.5 2 2 1 0.78090134718561421]
   [2.5 3 10 1 0.77079733675018158]
   [2.5 5 10 1 0.55997022179705502]
   [3.9 8 10 1 0.79127467607091229]
   [2.5 8 30000 1 0.35790434315864494]
   [2.5 3 10 2 0.61499204879261726]
   [2.5 2 30000 5 0.66953538076510777]]
  (def got (first (janet-num/unpack-f64
                    (janet-num/ptukey-v (janet-num/pack-f64 @[q]) k df rr))))
  (assert (<= (math/abs (- got want)) (* 1e-9 (math/abs want)))
          (string "ptukey-v R spot " q " " k " " df)))
(each [q want] [[0 0] [-1.5 0] [math/inf 1]]
  (def got (first (janet-num/unpack-f64
                    (janet-num/ptukey-v (janet-num/pack-f64 @[q]) 3 10 1))))
  (assert (= got want) (string "ptukey-v pole q=" q)))
# NaN q -> the caller's NaN unchanged (R's ptukey.c ISNAN gate, the full
# 4-arg form). R's ptukey(NaN) is NaN, NOT
# 1 - the pole is a distinct decode from +inf. Two branches: q-NaN
# -> q (preserve the caller's NaN payload/sign); param-NaN -> NaN (a
# canonical NaN, R's ML_WARN_return_NAN). Assert via (not= x x) (janet
# NaN is never = to anything, incl. itself) AND a SOUND bit-pattern check:
# feed a NON-canonical NaN (a negative-sign NaN) so the assert
# distinguishes "return q (preserve)" from "return NAN (canonicalize)" -
# math/nan IS the canonical quiet NaN, so asserting on it is vacuous.
# SCOPE: this asserts the RAW KERNEL's bit-preservation, called
# directly via ptukey-v. The public dist/ptukey surface validates the
# domain (nmeans>=2, df>=2, nranges>=1) caller-side, so a non-canonical
# NaN reaches the kernel only when a caller bypasses that validation -
# the assert does NOT demonstrate preservation through the public API.
(def nan-q (first (janet-num/unpack-f64
                    (janet-num/ptukey-v (janet-num/pack-f64 @[math/nan]) 3 10 1))))
(assert (not= nan-q nan-q) "ptukey-v pole q=NaN -> NaN (R's ISNAN gate)")
(defn f64-bits [x] (first (janet-num/unpack-u64 (janet-num/pack-f64 @[x]))))
(def neg-nan (first (janet-num/unpack-f64 (janet-num/pack-u64 @[(int/u64 (string "18444492273895915520"))]))))
(def neg-nan-q (first (janet-num/unpack-f64
                        (janet-num/ptukey-v (janet-num/pack-f64 @[neg-nan]) 3 10 1))))
(assert (= (string (f64-bits neg-nan-q)) (string (f64-bits neg-nan)))
        "ptukey-v NaN payload preserved (non-canonical -NaN round-trips)")
(def param-nan-q (first (janet-num/unpack-f64
                          (janet-num/ptukey-v (janet-num/pack-f64 @[2.5]) math/nan 30000 1))))
(assert (not= param-nan-q param-nan-q)
        "ptukey-v param-NaN + finite q -> NaN (R's ML_WARN_return_NAN)")
(assert-raises (fn [] (janet-num/ptukey-v bad-w 3 10 1)) "needs 8-byte elements")

# -- GC-pressure stress (regression: col buffers once went out of scope
# before the kernel call - small fixtures passed by luck, 100k segfaulted)
(def big-cols (lcg-cols 16 200000))
(def big-pack (janet-num/pack-columns-f32 big-cols))
(def big-slice (janet-num/packed-slice-f32 big-pack 3))
(defn f32-of [v] (f32-of-dyadic (* v 2147483648)))
(assert-eq big-slice
  @[(f32-of (get (get big-cols 0) 0))
    (f32-of (get (get big-cols 1) 0))
    (f32-of (get (get big-cols 2) 0))]
  "large pack under GC pressure stays exact")
(:free big-pack)

(print "janet-num smoke ok")
