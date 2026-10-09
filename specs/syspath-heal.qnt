// syspath-heal.qnt - decision-table spec of the syspath self-heal
// (janet-num 0.1.0; decision: never-clobber core +
// existence-scoped candidate list, owner 2026-10-09; HOME nil/empty
// blocks the entire heal - R1, confirmed 2026-10-09).
//
// The contract verified (one heal invocation, the module-load-time code):
//   1. NEVER CLOBBER: a non-default, non-empty inherited syspath is
//      never replaced (a $JANET_PATH-seeded syspath is respected).
//   2. HOME GUARD: HOME nil or empty -> the heal is a full no-op.
//   3. Heal is allowed only when the inherited syspath is empty or the
//      compile default; then it sets the FIRST EXISTING dir of the
//      ordered short list (user lib, /usr/local/lib/janet, /usr/lib/janet).
//   4. The healed syspath is a single dir (never a concatenation).
//   5. If no candidate exists, the heal is a no-op (the import then
//      fails actionably naming $JANET_PATH - outside this model).

module syspathHeal {

  type HomeState = str            // "nil" | "empty" | "set"
  type Dir = str

  pure def EMPTY: Dir = ""
  pure def COMPILE_DEFAULT: Dir = "/usr/local/lib/janet"
  pure def USER_LIB: Dir = "/home/u/.local/lib/janet"   // HOME-derived
  pure def USR_LIB: Dir = "/usr/lib/janet"
  // any valid inherited syspath that is neither empty nor the compile
  // default (e.g. seeded from $JANET_PATH)
  pure def OTHER_SYS: Set[Dir] = Set("/env/janet-path", "/opt/janet")

  // the ordered short list (first existing wins)
  pure def firstExisting(e: Set[Dir]): Dir =
    if (e.contains(USER_LIB)) USER_LIB
    else if (e.contains(COMPILE_DEFAULT)) COMPILE_DEFAULT
    else if (e.contains(USR_LIB)) USR_LIB
    else "none"

  // THE decision table: {home, inherited syspath} x existing dirs -> action
  pure def healAction(h: HomeState, s: Dir, e: Set[Dir]): Dir =
    if (h != "set") s                                     // home guard: full no-op
    else if (not(s == EMPTY or s == COMPILE_DEFAULT)) s   // never clobber
    else if (firstExisting(e) == "none") s                // nothing to heal to
    else firstExisting(e)

  var home: HomeState
  var sysIn: Dir          // the inherited syspath
  var existing: Set[Dir]  // which candidate dirs exist on this machine
  var sysOut: Dir         // the syspath after the heal

  // all input combinations the environment can present
  action init =
    nondet h = Set("nil", "empty", "set").oneOf();
    nondet s = Set(EMPTY).union(Set(COMPILE_DEFAULT)).union(OTHER_SYS).oneOf();
    nondet e = Set(
      Set(),
      Set(USER_LIB),
      Set(COMPILE_DEFAULT),
      Set(USR_LIB),
      Set(USER_LIB, COMPILE_DEFAULT),
      Set(USER_LIB, USR_LIB),
      Set(COMPILE_DEFAULT, USR_LIB),
      Set(USER_LIB, COMPILE_DEFAULT, USR_LIB)
    ).oneOf();
    all {
    home' = h,
    sysIn' = s,
    existing' = e,
    sysOut' = s,
    }

  // the heal runs once, then the process idles
  action applyHeal = all {
    sysOut' = healAction(home, sysIn, existing),
    home' = home,
    sysIn' = sysIn,
    existing' = existing,
  }

  action idle = all {
    home' = home,
    sysIn' = sysIn,
    existing' = existing,
    sysOut' = sysOut,
  }

  action step = any {
    applyHeal,
    idle,
  }

  // ---- the contract, as state invariants -------------------------

  // 1. never clobber a non-default, non-empty inherited syspath
  val neverClobber = not(OTHER_SYS.contains(sysIn) and sysOut != sysIn)

  // 2. HOME nil/empty -> full no-op
  val homeGuard = (home != "set") implies (sysOut == sysIn)

  // 3. a heal (sysOut != sysIn) happens only from empty/compile-default,
  //    only with HOME set, and lands on exactly the first existing
  //    candidate
  val healOnlyFromDefault = (sysOut != sysIn) implies all {
    home == "set",
    sysIn == EMPTY or sysIn == COMPILE_DEFAULT,
    sysOut == firstExisting(existing),
    existing != Set(),
  }

  // 4. the healed syspath is a single candidate dir (never a concat,
  //    never a guessed nonexistent path)
  val singleDir = (sysOut == sysIn) or Set(USER_LIB, COMPILE_DEFAULT, USR_LIB).contains(sysOut)

  val inv = all {
    neverClobber,
    homeGuard,
    healOnlyFromDefault,
    singleDir,
  }
}
