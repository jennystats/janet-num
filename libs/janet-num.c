/* janet-num - small numeric kernels for the Janet data stack.
 * License: AGPLv3 (see LICENSE in the package root).
 *
 * Plain C library, dlopen'd via Janet core ffi. NOT a native module:
 * no Janet symbols, no embedding API.
 * Built from source by libs/install-janet-num.sh.
 *
 * Buffer policy: kernels NEVER allocate. The caller (Janet) owns all
 * memory; kernels only read and write caller buffers. The Janet layer
 * passes GC-managed buffers; the handle's :free is a no-op kept for
 * `with` compatibility.
 *
 * Build: gcc -O2 -shared -fPIC -o libjn.so janet-num.c
 * Slice 1: the pack/unpack kernels (column-major double arrays ->
 * row-major packed buffers, one C pass).
 */

#include <stddef.h>
#include <stdint.h>
#include <math.h>

const char *jn_version(void) { return "0.1.0"; }

/*
 * Slice 2: vmap/vzip/vreduce/vscan + fused ops over packed buffers.
 * Ops are enums (Janet fns cannot cross ffi as C fn pointers - the
 * numpy-ufunc model). Accumulation is strictly sequential (bitwise
 * agreement with the pure-Janet oracles; no -ffast-math). i64 math is
 * done in unsigned internally: signed overflow is UB in C, wraparound
 * is the documented, defined behaviour here.
 */
enum { JN_ADD = 0, JN_SUB, JN_MUL, JN_DIV, JN_MIN, JN_MAX, JN_ABS, JN_NEG,
       JN_EXP, JN_LOG }; /* exp/log: density compositions */
enum { JN_SUM = 0, JN_PROD, JN_RMIN, JN_RMAX, JN_SUMSQ };

/* ---------- f64: elementwise ---------- */
void jn_vmap1_f64(int op, const double *a, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        double x = a[i];
        switch (op) {
        case JN_ABS: out[i] = fabs(x); break;
        case JN_NEG: out[i] = -x; break;
        case JN_EXP: out[i] = exp(x); break;
        case JN_LOG: out[i] = log(x); break;
        default: out[i] = x; break;
        }
    }
}

void jn_vmap2_f64(int op, const double *a, const double *b, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        double x = a[i], y = b[i];
        switch (op) {
        case JN_ADD: out[i] = x + y; break;
        case JN_SUB: out[i] = x - y; break;
        case JN_MUL: out[i] = x * y; break;
        case JN_DIV: out[i] = x / y; break;
        case JN_MIN: out[i] = x < y ? x : y; break;
        case JN_MAX: out[i] = x > y ? x : y; break;
        default: out[i] = x; break;
        }
    }
}

void jn_vmap1s_f64(int op, const double *a, double k, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        double x = a[i];
        switch (op) {
        case JN_ADD: out[i] = x + k; break;
        case JN_SUB: out[i] = x - k; break;
        case JN_MUL: out[i] = x * k; break;
        case JN_DIV: out[i] = x / k; break;
        default: out[i] = x; break;
        }
    }
}

/* ---------- f64: reduce / scan / fused ---------- */
double jn_vreduce_f64(int op, const double *a, size_t n) {
    if (n == 0) return 0.0;
    double acc = (op == JN_SUMSQ) ? a[0] * a[0] : a[0];
    for (size_t i = 1; i < n; i++) {
        double x = a[i];
        switch (op) {
        case JN_SUM: acc += x; break;
        case JN_PROD: acc *= x; break;
        case JN_RMIN: if (x < acc) acc = x; break;
        case JN_RMAX: if (x > acc) acc = x; break;
        case JN_SUMSQ: acc += x * x; break;
        default: break;
        }
    }
    return acc;
}

void jn_vscan_f64(int op, const double *a, size_t n, double *out) {
    if (n == 0) return;
    out[0] = a[0];
    for (size_t i = 1; i < n; i++) {
        double x = a[i], prev = out[i - 1];
        switch (op) {
        case JN_SUM: out[i] = prev + x; break;
        case JN_PROD: out[i] = prev * x; break;
        case JN_RMIN: out[i] = x < prev ? x : prev; break;
        case JN_RMAX: out[i] = x > prev ? x : prev; break;
        default: out[i] = x; break;
        }
    }
}

void jn_vzip_f64(const double *a, const double *b, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = a[i];
        out[2 * i + 1] = b[i];
    }
}

double jn_vdot_f64(const double *a, const double *b, size_t n) {
    double acc = 0.0;
    for (size_t i = 0; i < n; i++) acc += a[i] * b[i];
    return acc;
}

void jn_vaxpy_f64(double alpha, const double *x, double *y, size_t n) {
    for (size_t i = 0; i < n; i++) y[i] += alpha * x[i];
}

/* ---------- i64 (unsigned internal math: defined wraparound) ---------- */
void jn_vmap2_i64(int op, const int64_t *a, const int64_t *b, size_t n, int64_t *out) {
    for (size_t i = 0; i < n; i++) {
        uint64_t x = (uint64_t)a[i], y = (uint64_t)b[i], r = 0;
        switch (op) {
        case JN_ADD: r = x + y; break;
        case JN_SUB: r = x - y; break;
        case JN_MUL: r = x * y; break;
        case JN_MIN: r = a[i] < b[i] ? x : y; break;
        case JN_MAX: r = a[i] > b[i] ? x : y; break;
        default: r = x; break;
        }
        out[i] = (int64_t)r;
    }
}

void jn_vmap1s_i64(int op, const int64_t *a, int64_t k, size_t n, int64_t *out) {
    for (size_t i = 0; i < n; i++) {
        uint64_t x = (uint64_t)a[i], kk = (uint64_t)k, r = 0;
        switch (op) {
        case JN_ADD: r = x + kk; break;
        case JN_SUB: r = x - kk; break;
        case JN_MUL: r = x * kk; break;
        default: r = x; break;
        }
        out[i] = (int64_t)r;
    }
}

int64_t jn_vreduce_i64(int op, const int64_t *a, size_t n) {
    if (n == 0) return 0;
    uint64_t acc = (uint64_t)a[0];
    for (size_t i = 1; i < n; i++) {
        int64_t x = a[i];
        switch (op) {
        case JN_SUM: acc += (uint64_t)x; break;
        case JN_RMIN: if (x < (int64_t)acc) acc = (uint64_t)x; break;
        case JN_RMAX: if (x > (int64_t)acc) acc = (uint64_t)x; break;
        default: break;
        }
    }
    return (int64_t)acc;
}

void jn_vscan_i64(int op, const int64_t *a, size_t n, int64_t *out) {
    if (n == 0) return;
    uint64_t acc = (uint64_t)a[0];
    out[0] = a[0];
    for (size_t i = 1; i < n; i++) {
        int64_t x = a[i];
        switch (op) {
        case JN_SUM: acc += (uint64_t)x; break;
        case JN_RMIN: if (x < (int64_t)acc) acc = (uint64_t)x; break;
        case JN_RMAX: if (x > (int64_t)acc) acc = (uint64_t)x; break;
        default: break;
        }
        out[i] = (int64_t)acc;
    }
}

/* ---------- i32 ---------- */
void jn_vmap2_i32(int op, const int32_t *a, const int32_t *b, size_t n, int32_t *out) {
    for (size_t i = 0; i < n; i++) {
        int32_t x = a[i], y = b[i], r = 0;
        switch (op) {
        case JN_ADD: r = (int32_t)((uint32_t)x + (uint32_t)y); break;
        case JN_SUB: r = (int32_t)((uint32_t)x - (uint32_t)y); break;
        case JN_MUL: r = (int32_t)((uint32_t)x * (uint32_t)y); break;
        case JN_MIN: r = x < y ? x : y; break;
        case JN_MAX: r = x > y ? x : y; break;
        default: r = x; break;
        }
        out[i] = r;
    }
}

int64_t jn_vreduce_i32(int op, const int32_t *a, size_t n) {
    if (n == 0) return 0;
    int64_t acc = a[0];
    for (size_t i = 1; i < n; i++) {
        int32_t x = a[i];
        switch (op) {
        case JN_SUM: acc += x; break;
        case JN_RMIN: if (x < acc) acc = x; break;
        case JN_RMAX: if (x > acc) acc = x; break;
        default: break;
        }
    }
    return acc;
}

void jn_vscan_i32(int op, const int32_t *a, size_t n, int32_t *out) {
    if (n == 0) return;
    int32_t acc = a[0];
    out[0] = a[0];
    for (size_t i = 1; i < n; i++) {
        int32_t x = a[i];
        switch (op) {
        case JN_SUM: acc = (int32_t)((uint32_t)acc + (uint32_t)x); break;
        case JN_RMIN: if (x < acc) acc = x; break;
        case JN_RMAX: if (x > acc) acc = x; break;
        default: break;
        }
        out[i] = acc;
    }
}


/*
 * Interleave staged columns into a row-major float32 buffer - the
 * XGDMatrixCreateFromMat ingest shape. Columns are staged into ONE
 * shared buffer (col c at staging[c*nrow .. c*nrow+nrow)), written by
 * the Janet layer via ffi/write offsets - no per-column buffers, no
 * pointer table (allocation churn measured 7x slower than shared
 * staging).
 * Row-outer loop: sequential stores to `out`, loads cycle ncol column
 * segments (L1-resident for realistic ncol).
 */
void jn_interleave_f32(const double *staging, size_t ncol, size_t nrow,
                       float *out) {
    for (size_t r = 0; r < nrow; r++) {
        float *row = out + r * ncol;
        for (size_t c = 0; c < ncol; c++) {
            row[c] = (float)staging[c * nrow + r];
        }
    }
}

/* Same, row-major double output (generic packing path). */
void jn_interleave_f64(const double *staging, size_t ncol, size_t nrow,
                       double *out) {
    for (size_t r = 0; r < nrow; r++) {
        double *row = out + r * ncol;
        for (size_t c = 0; c < ncol; c++) {
            row[c] = staging[c * nrow + r];
        }
    }
}

/*
 * Integer/bitset kernels (bit-set workloads
 * evaluation over packed bit-vectors is the second consumer). Flat
 * uint64_t word arrays - bit-vectors are flat, no column interleave.
 */
#include <stdint.h>

void jn_band_u64(const uint64_t *a, const uint64_t *b, size_t n,
                 uint64_t *out) {
    for (size_t i = 0; i < n; i++) out[i] = a[i] & b[i];
}

void jn_bor_u64(const uint64_t *a, const uint64_t *b, size_t n,
                uint64_t *out) {
    for (size_t i = 0; i < n; i++) out[i] = a[i] | b[i];
}

void jn_bxor_u64(const uint64_t *a, const uint64_t *b, size_t n,
                 uint64_t *out) {
    for (size_t i = 0; i < n; i++) out[i] = a[i] ^ b[i];
}

void jn_popcount_u64(const uint64_t *a, size_t n, uint64_t *out) {
    for (size_t i = 0; i < n; i++) {
        uint64_t v = a[i];
        /* popcount via bit-twiddling (SWAR); gcc -O2 may use popcnt */
        v = v - ((v >> 1) & 0x5555555555555555ULL);
        v = (v & 0x3333333333333333ULL) + ((v >> 2) & 0x3333333333333333ULL);
        v = (v + (v >> 4)) & 0x0F0F0F0F0F0F0F0FULL;
        out[i] = (v * 0x0101010101010101ULL) >> 56;
    }
}

/*
 * C-to-C interleave: pointer tables of raw column buffers (e.g. database
 * chunk vectors - data already in native memory) + optional per-column
 * validity bitmaps, straight into a row-major float32 buffer at
 * row_offset. NULL/invalid entries become NaN (the `missing`
 * semantics). This is the zero-janet-elements ingest path: no tagged
 * arrays, no staging, one C pass per chunk.
 * Bitmaps: mask == NULL means all rows valid; else bit r of word r/64.
 */
void jn_interleave_f32_null(const double *const *cols, const uint64_t *const *masks,
                            size_t ncol, size_t nrow, size_t row_offset,
                            float *out) {
    for (size_t r = 0; r < nrow; r++) {
        float *row = out + (row_offset + r) * ncol;
        for (size_t c = 0; c < ncol; c++) {
            const uint64_t *m = masks[c];
            int valid = (m == NULL) || ((m[r >> 6] >> (r & 63)) & 1ULL);
            row[c] = valid ? (float)cols[c][r] : (float)NAN;
        }
    }
}

/* Unpack: row-major float32 buffer -> per-column double buffers. */
void jn_deinterleave_f32(const float *in, size_t ncol, size_t nrow,
                         double *const *cols) {
    for (size_t r = 0; r < nrow; r++) {
        const float *row = in + r * ncol;
        for (size_t c = 0; c < ncol; c++) {
            cols[c][r] = (double)row[c];
        }
    }
}

/* Unpack: row-major double buffer -> per-column double buffers. */
void jn_deinterleave_f64(const double *in, size_t ncol, size_t nrow,
                         double *const *cols) {
    for (size_t r = 0; r < nrow; r++) {
        const double *row = in + r * ncol;
        for (size_t c = 0; c < ncol; c++) {
            cols[c][r] = row[c];
        }
    }
}

/*
 * Slice 3: special-function vector kernels + matvec + row distances.
 * The CF/series forms follow the standard continued-fraction and
 * series algorithms (Lentz, NR-style, same branch conditions) so
 * kernel and pure paths agree to round-off.
 * erf/erfc/lgamma use libm (lgamma_r - reentrant, no global state).
 * Kernels never allocate; a<=0 / x<0 inputs mirror the janet-side
 * guards (callers validate; NaN in, NaN out).
 */
#define JN_GAMMA_MAXIT 1000
#define JN_GAMMA_EPS 1e-15
#define JN_TINY 1e-300

void jn_erf_f64(const double *a, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) out[i] = erf(a[i]);
}

void jn_erfc_f64(const double *a, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) out[i] = erfc(a[i]);
}

void jn_lgamma_f64(const double *a, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        int sign = 0;
        out[i] = lgamma_r(a[i], &sign);
    }
}

void jn_log_beta_f64(const double *a, const double *b, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        int s = 0;
        out[i] = lgamma_r(a[i], &s) + lgamma_r(b[i], &s)
                 - lgamma_r(a[i] + b[i], &s);
    }
}

/* P(a,x) series for x < a+1 (NR gser, mirrored). */
static double jn_gamma_p_series(double a, double x) {
    double ap = a;
    double sum = 1.0 / a;
    double del = sum;
    for (int i = 0; i < JN_GAMMA_MAXIT; i++) {
        ap += 1.0;
        del *= x / ap;
        sum += del;
        if (fabs(del) < fabs(sum) * JN_GAMMA_EPS) break;
    }
    return sum * exp(a * log(x) - x - lgamma(a));
}

/* Q(a,x) continued fraction for x >= a+1 (NR gcf, mirrored). */
static double jn_gamma_q_cf(double a, double x) {
    double b = x + 1.0 - a;
    double c = 1.0 / JN_TINY;
    double d = 1.0 / b;
    double h = d;
    for (int i = 1; i < JN_GAMMA_MAXIT; i++) {
        double an = -(double)i * ((double)i - a);
        b += 2.0;
        d = an * d + b;
        if (fabs(d) < JN_TINY) d = JN_TINY;
        c = b + an / c;
        if (fabs(c) < JN_TINY) c = JN_TINY;
        d = 1.0 / d;
        double del = d * c;
        h *= del;
        if (fabs(del - 1.0) < JN_GAMMA_EPS) break;
    }
    return h * exp(a * log(x) - x - lgamma(a));
}

/* Regularized lower incomplete gamma P(a,x), x >= 0. */
static double jn_gamma_p_one(double a, double x) {
    if (x == 0.0) return 0.0;
    if (x < a + 1.0) return jn_gamma_p_series(a, x);
    return 1.0 - jn_gamma_q_cf(a, x);
}

void jn_gamma_p_f64(const double *a, const double *x, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) out[i] = jn_gamma_p_one(a[i], x[i]);
}

void jn_gamma_q_f64(const double *a, const double *x, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        double p = jn_gamma_p_one(a[i], x[i]);
        out[i] = 1.0 - p;
    }
}

/* Continued fraction for I_x(a,b) (NR betacf, mirrored). */
static double jn_beta_cf(double a, double b, double x) {
    double qab = a + b;
    double qap = a + 1.0;
    double qam = a - 1.0;
    double c = 1.0;
    double d = 1.0 - qab * x / qap;
    if (fabs(d) < JN_TINY) d = JN_TINY;
    d = 1.0 / d;
    double h = d;
    for (int m = 1; m <= 5000; m++) {
        double m2 = 2.0 * (double)m;
        double aa = (double)m * ((double)b - (double)m) * x
                    / ((qam + m2) * (a + m2));
        d = 1.0 + aa * d;
        if (fabs(d) < JN_TINY) d = JN_TINY;
        c = 1.0 + aa / c;
        if (fabs(c) < JN_TINY) c = JN_TINY;
        d = 1.0 / d;
        h *= d * c;
        double aa2 = (-(a + (double)m)) * (qab + (double)m) * x
                     / ((a + m2) * (qap + m2));
        d = 1.0 + aa2 * d;
        if (fabs(d) < JN_TINY) d = JN_TINY;
        c = 1.0 + aa2 / c;
        if (fabs(c) < JN_TINY) c = JN_TINY;
        d = 1.0 / d;
        double del = d * c;
        h *= del;
        if (fabs(del - 1.0) < 3.0 * 1e-15) break;
    }
    return h;
}

/* Regularized incomplete beta I_x(a,b), 0 <= x <= 1 (mirrored front
 * end incl. the symmetric swap; log-space combination). */
static double jn_beta_inc_one(double a, double b, double x) {
    if (x == 0.0) return 0.0;
    if (x == 1.0) return 1.0;
    if (x > (a + 1.0) / (a + b + 2.0))
        return 1.0 - jn_beta_inc_one(b, a, 1.0 - x);
    double lbt = -lgamma(a) - lgamma(b) + lgamma(a + b)
                 + a * log(x) + b * log1p(-x);
    return exp(lbt + log(jn_beta_cf(a, b, x))) / a;
}

void jn_beta_inc_f64(const double *a, const double *b, const double *x,
                     size_t n, double *out) {
    for (size_t i = 0; i < n; i++)
        out[i] = jn_beta_inc_one(a[i], b[i], x[i]);
}

/* Fused standard-normal CDF with the erfc sign branch (mirrors
 * the erfc route avoids cancellation in
 * both tails; not composable from the vmap op set). */
void jn_pnorm_f64(const double *a, double mean, double sd, size_t n,
                  double *out) {
    for (size_t i = 0; i < n; i++) {
        double z = (a[i] - mean) / sd;
        double s = z < 0 ? -1.0 : 1.0;
        double p = 0.5 * erfc(s * z / 1.4142135623730951);
        out[i] = z < 0 ? p : 1.0 - p;
    }
}

/* Fused studentized-range CDF (v0.1.0): mirrors the verified
 * pure's quadrature (R's ptukey.c decoded, Copenhaver-Holland 1988)
 * formula for formula: same constants, same gates, same break rules.
 * phi/lgamma use libm (the pure's reference helpers differ by ulps;
 * the parity bar is kernel-abi section 4). No k/df/rr validation
 * here: the domain contract is documented in the ABI row; the caller
 * (the stats layer) validates. */
static const double jn_tukey_xleg[6] = {
    0.981560634246719250690549090149, 0.904117256370474856678465866119,
    0.769902674194304687036893833213, 0.587317954286617447296702418941,
    0.367831498998180193752691536644, 0.125233408511468915472441369464};
static const double jn_tukey_aleg[6] = {
    0.047175336386511827194615961485, 0.106939325995318430960254718194,
    0.160078328543346226334652529543, 0.203167426723065921749064455810,
    0.233492536538354808760849898925, 0.249147045813402785000562436043};
static const double jn_tukey_xlegq[8] = {
    0.989400934991649932596154173450, 0.944575023073232576077988415535,
    0.865631202387831743880467897712, 0.755404408355003033895101194847,
    0.617876244402643748446671764049, 0.458016777657227386342419442984,
    0.281603550779258913230460501460, 0.0950125098376374401853193354250};
static const double jn_tukey_alegq[8] = {
    0.0271524594117540948517805724560, 0.0622535239386478928628438369944,
    0.0951585116824927848099251076022, 0.124628971255533872052476282192,
    0.149595988816576732081501730547, 0.169156519395002538189312079030,
    0.182603415044923588866763667969, 0.189450610455068496285396723208};

static double jn_phi(double x) { return 0.5 * erfc(-x / 1.4142135623730951); }

/* Hartley's range integral: 12-point Legendre over [w/2, 8] in 2-3
 * intervals, the C1/C2/C3 gates, the qexpo > 60 break. */
static double jn_tukey_wprob(double w, double rr, double cc) {
    double qsqz = w * 0.5;
    if (qsqz >= 8.0) return 1.0;
    double pr_w0 = 2.0 * jn_phi(qsqz) - 1.0;
    double pr_w = (pr_w0 >= exp(-50.0 / cc)) ? pow(pr_w0, cc) : 0.0;
    double wincr = (w > 3.0) ? 2.0 : 3.0;
    double cc1 = cc - 1.0;
    double binc = (8.0 - qsqz) / wincr;
    double blb = qsqz;
    double bub = blb + binc;
    double einsum = 0.0;
    for (int wi = 1; wi < wincr + 1; wi++) {
        double elsum = 0.0;
        double a = 0.5 * (bub + blb);
        double b = 0.5 * (bub - blb);
        for (int jj = 1; jj < 13; jj++) {
            int j = (jj <= 6) ? jj : 13 - jj;
            double xx = (jj <= 6) ? -jn_tukey_xleg[j - 1]
                                 : jn_tukey_xleg[j - 1];
            double ac = a + b * xx;
            double qexpo = ac * ac;
            if (qexpo > 60.0) break;
            double pplus = 2.0 * jn_phi(ac);
            double pminus = 2.0 * jn_phi(ac - w);
            double rinsum = 0.5 * pplus - 0.5 * pminus;
            if (rinsum >= exp(-30.0 / cc1))
                elsum += jn_tukey_aleg[j - 1] * exp(-0.5 * qexpo)
                         * pow(rinsum, cc1);
        }
        elsum *= 2.0 * b * cc * 0.398942280401432677939946059934;
        einsum += elsum;
        blb = bub;
        bub += binc;
    }
    double pr_w2 = pr_w + einsum;
    if (pr_w2 <= exp(-30.0 / rr)) return 0.0;
    double pw = pow(pr_w2, rr);
    return (pw >= 1.0) ? 1.0 : pw;
}

/* The CDF: df > 25000 -> wprob directly; else the chi-density
 * integral (16-point Legendre, up to 50 outer intervals). The break
 * rule DISCARDS the final sub-eps interval (ans += sits after the
 * break), mirroring the pure exactly. */
static double jn_tukey_cdf(double q, double rr, double cc, double df) {
    /* NaN in ANY arg -> a NaN out (R's ptukey.c ISNAN gate, the full
     * 4-arg form). The NaN pole is a
     * DISTINCT decode from +inf (which is 1): R's ptukey.c tests
     * ISNAN(q) || ISNAN(rr) || ISNAN(cc) || ISNAN(df) FIRST, before the
     * q<=0 and !R_FINITE gates. TWO branches: q-NaN -> q (preserve
     * the caller's NaN payload/sign); param-NaN (rr/cc/df) -> NAN (a
     * canonical NaN, R's ML_WARN_return_NAN = return R_NaN - NOT q, which
     * would be a FINITE value for finite q, violating "NaN in, NaN out").
     * Mirrors the pure's tukey-cdf cond, which carries the same gate. */
    if (isnan(q)) return q;
    if (isnan(rr) || isnan(cc) || isnan(df)) return NAN;
    if (q <= 0.0) return 0.0;
    if (!(q < INFINITY && q > -INFINITY)) return 1.0;
    if (df > 25000.0) return jn_tukey_wprob(q, rr, cc);
    double f2 = df * 0.5;
    int sign = 0;
    double ulen = (df <= 100.0) ? 1.0 : (df <= 800.0) ? 0.5
                : (df <= 5000.0) ? 0.25 : 0.125;
    double f2lf = f2 * log(df) - df * 0.693147180559945309417232121458
                  - lgamma_r(f2, &sign) + log(ulen);
    double f21 = f2 - 1.0;
    double ff4 = df * 0.25;
    double ans = 0.0;
    double otsum = 0.0;
    for (int i = 1; i < 51; i++) {
        otsum = 0.0;
        double twa1 = (2.0 * (double)i - 1.0) * ulen;
        for (int jj = 1; jj < 17; jj++) {
            int j = (jj <= 8) ? jj - 1 : jj - 9;
            double xu = jn_tukey_xlegq[j] * ulen;
            double t1 = (jj <= 8)
                ? f2lf + f21 * log(twa1 - xu) + (xu - twa1) * ff4
                : f2lf + f21 * log(twa1 + xu) - (xu + twa1) * ff4;
            if (t1 >= -30.0) {
                double inner = (jj <= 8) ? (twa1 - xu) : (twa1 + xu);
                double qsqz = q * sqrt(inner * 0.5);
                otsum += jn_tukey_wprob(qsqz, rr, cc)
                         * jn_tukey_alegq[j] * exp(t1);
            }
        }
        if ((double)i * ulen >= 1.0 && otsum <= 1e-14) break;
        ans += otsum;
    }
    /* janet's (min ans 1) propagates NaN; a plain ans<1.0 test
     * would turn an NaN tail into 1.0 instead. */
    return (1.0 < ans) ? 1.0 : ans;
}

void jn_ptukey_f64(const double *q, double nmeans, double df, double nranges,
                   size_t n, double *out) {
    for (size_t i = 0; i < n; i++)
        out[i] = jn_tukey_cdf(q[i], nranges, nmeans, df);
}

/* Row-major n x p matrix times p-vector -> n-vector. */
void jn_matvec_f64(const double *m, const double *v, size_t n, size_t p,
                   double *out) {
    for (size_t r = 0; r < n; r++) {
        const double *row = m + r * p;
        double s = 0.0;
        for (size_t j = 0; j < p; j++) s += row[j] * v[j];
        out[r] = s;
    }
}

/* Slice 3.5 (linalg tier, Option A - requirements-linalg.md): row-major
 * matrix kernels. LAPACK column-major is a recorded reason we own these
 * instead of binding system OpenBLAS. Status returns: 1 ok / 0 fail. */

/* C = A(m x k) . B(k x n), row-major. */
void jn_matmul_f64(const double *a, const double *b, size_t m, size_t k,
                   size_t n, double *out) {
    for (size_t i = 0; i < m; i++) {
        const double *row = a + i * k;
        double *orow = out + i * n;
        for (size_t j = 0; j < n; j++) orow[j] = 0.0;
        for (size_t t = 0; t < k; t++) {
            double av = row[t];
            if (av == 0.0) continue;
            const double *brow = b + t * n;
            for (size_t j = 0; j < n; j++) orow[j] += av * brow[j];
        }
    }
}

/* Lower Cholesky L (A = L L'), row-major, written into out (a copy).
 * Returns 0 if not positive-definite. */
int jn_cholesky_f64(const double *a, size_t n, double *out) {
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j <= i; j++) {
            double s = a[i * n + j];
            for (size_t t = 0; t < j; t++) s -= out[i * n + t] * out[j * n + t];
            if (i == j) {
                if (s <= 0.0) return 0;
                out[i * n + i] = sqrt(s);
            } else {
                out[i * n + j] = s / out[j * n + j];
            }
        }
        for (size_t j = i + 1; j < n; j++) out[i * n + j] = 0.0;
    }
    return 1;
}

/* Solve L L' x = b with lower L (row-major), in place into b. */
int jn_chol_solve_f64(const double *l, double *b, size_t n) {
    /* forward: L y = b */
    for (size_t i = 0; i < n; i++) {
        double s = b[i];
        for (size_t j = 0; j < i; j++) s -= l[i * n + j] * b[j];
        double d = l[i * n + i];
        if (d == 0.0) return 0;
        b[i] = s / d;
    }
    /* back: L' x = y */
    for (size_t ii = 0; ii < n; ii++) {
        size_t i = n - 1 - ii;
        double s = b[i];
        for (size_t j = i + 1; j < n; j++) s -= l[j * n + i] * b[j];
        b[i] = s / l[i * n + i];
    }
    return 1;
}

/* LU factor + solve with partial pivoting (row-major, LAPACK dgesv
 * structure). WORKSPACE IS CALLER-PROVIDED (n*n doubles - the
 * never-allocate policy; Janet passes a GC buffer). Returns 0 if
 * (near-)singular. */
int jn_lu_solve_f64(const double *a, double *b, size_t n, double *work) {
    double *lu = work;
    for (size_t i = 0; i < n * n; i++) lu[i] = a[i];
    for (size_t col = 0; col < n; col++) {
        size_t piv = col;
        double best = fabs(lu[col * n + col]);
        for (size_t r = col + 1; r < n; r++) {
            double v = fabs(lu[r * n + col]);
            if (v > best) { best = v; piv = r; }
        }
        if (best < 1e-300) return 0;
        if (piv != col) {
            for (size_t c = 0; c < n; c++) {
                double t = lu[col * n + c];
                lu[col * n + c] = lu[piv * n + c];
                lu[piv * n + c] = t;
            }
            double tb = b[col];
            b[col] = b[piv];
            b[piv] = tb;
        }
        double diag = lu[col * n + col];
        for (size_t r = col + 1; r < n; r++) {
            double f = lu[r * n + col] / diag;
            if (f != 0.0) {
                for (size_t c = col; c < n; c++)
                    lu[r * n + c] -= f * lu[col * n + c];
                b[r] -= f * b[col];
            }
        }
    }
    for (size_t ii = 0; ii < n; ii++) {
        size_t i = n - 1 - ii;
        double s = b[i];
        for (size_t j = i + 1; j < n; j++) s -= lu[i * n + j] * b[j];
        b[i] = s / lu[i * n + i];
    }
    return 1;
}

/* Squared euclidean distances: n x p points vs k x p centers -> n x k
 * row-major. (Distance kernels: the k-means hot loop.) */
void jn_dist2_rows_f64(const double *x, const double *c, size_t n, size_t p,
                       size_t k, double *out) {
    for (size_t r = 0; r < n; r++) {
        const double *row = x + r * p;
        for (size_t j = 0; j < k; j++) {
            const double *ctr = c + j * p;
            double s = 0.0;
            for (size_t d = 0; d < p; d++) {
                double diff = row[d] - ctr[d];
                s += diff * diff;
            }
            out[r * k + j] = s;
        }
    }
}
