// impl-resolution.qnt - formal spec of the impl resolution contract.
// Model of ONE Janet process (user decisions 2026-10-02: default = :impl;
// explicit :num strict;
// only :impl switches dynamically; the current end state has no un-landed
// functions, so every call resolves - never "not landed" raises here).
//
// The contract verified:
//   1. The loader probe happens AT MOST ONCE per process (the presence
//      flag is set once and never re-probed; janet does not cache
//      failed loads - the flag exists precisely to make the probe once).
//   2. Explicit :num NEVER silently falls back to pure: it returns num
//      or throws (error). Errors come ONLY from explicit :num.
//   3. :impl resolves dynamically (num if libjn present, pure if
//      absent) and NEVER errors.
//   4. :pure never probes the loader (and never errors).
//   5. The flag leaves "unknown" exactly when the probe happened, and
//      never changes afterwards (flag stability).

module implResolution {

  // presence flag of libjn for this process
  pure def UNKNOWN: str = "unknown"
  pure def PRESENT: str = "present"
  pure def ABSENT: str = "absent"

  var flag: str            // UNKNOWN | PRESENT | ABSENT
  var probeCount: int      // loader invocations so far (at most 1)
  var lastCall: str        // "impl" | "num" | "pure"
  var lastResult: str      // "num" | "pure" | "error"
  var lastProbed: bool     // did the latest call probe the loader?

  action init = all {
    flag' = UNKNOWN,
    probeCount' = 0,
    lastCall' = "pure",
    lastResult' = "pure",
    lastProbed' = false,
  }

  // ---- :impl - the ONLY dynamic path ----------------------------
  // from unknown: probe once; the machine decides the outcome
  action implProbe =
    nondet outcome = Set(PRESENT, ABSENT).oneOf();
    all {
      flag == UNKNOWN,
      probeCount' = probeCount + 1,
      flag' = outcome,
      lastCall' = "impl",
      lastProbed' = true,
      lastResult' = if (outcome == PRESENT) "num" else "pure",
    }

  // from resolved: use the cached flag, never re-probe
  action implCached = all {
    flag != UNKNOWN,
    flag' = flag,
    probeCount' = probeCount,
    lastCall' = "impl",
    lastProbed' = false,
    lastResult' = if (flag == PRESENT) "num" else "pure",
  }

  // ---- explicit :num - STRICT ------------------------------------
  // from unknown: probe once; error if the library turns out absent
  action numProbe =
    nondet outcome = Set(PRESENT, ABSENT).oneOf();
    all {
      flag == UNKNOWN,
      probeCount' = probeCount + 1,
      flag' = outcome,
      lastCall' = "num",
      lastProbed' = true,
      lastResult' = if (outcome == PRESENT) "num" else "error",
    }

  // from resolved: num if present, THROW if absent - no probe, no fallback
  action numCached = all {
    flag != UNKNOWN,
    flag' = flag,
    probeCount' = probeCount,
    lastCall' = "num",
    lastProbed' = false,
    lastResult' = if (flag == PRESENT) "num" else "error",
  }

  // ---- :pure - never loads the library ----------------------------
  action callPure = all {
    flag' = flag,
    probeCount' = probeCount,
    lastCall' = "pure",
    lastProbed' = false,
    lastResult' = "pure",
  }

  action step = any {
    implProbe,
    implCached,
    numProbe,
    numCached,
    callPure,
  }

  // ---- the contract, as state invariants --------------------------

  // 1. at most one loader probe per process
  val probeAtMostOnce = probeCount <= 1

  // 2. explicit :num never silently computes via the pure path
  val numNeverSilentlyPure = not(lastCall == "num" and lastResult == "pure")

  // 3. errors come ONLY from explicit :num
  val errorOnlyFromNum = not(lastResult == "error" and lastCall != "num")

  // 4. :pure never probes the loader
  val pureNeverProbes = not(lastCall == "pure" and lastProbed)

  // 5. the flag is resolved iff the probe happened (and by 1, at most once)
  val flagResolvesOnProbe = (flag == UNKNOWN) == (probeCount == 0)

  // 6. :impl never errors - the dynamic path always resolves
  val implNeverErrors = not(lastCall == "impl" and lastResult == "error")

  val inv = and {
    probeAtMostOnce,
    numNeverSilentlyPure,
    errorOnlyFromNum,
    pureNeverProbes,
    flagResolvesOnProbe,
    implNeverErrors,
  }
}
