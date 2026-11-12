# project.janet - jpm package manifest for janet-num.
(declare-project
  :name "janet-num"
  :description "Small C kernels for Janet's numeric hot paths, via core ffi - no native module"
  :license "AGPL-3.0"
  :version "0.1.4"
  :dependencies ["https://github.com/jennystats/janet-kit"])

(declare-source
  :source ["jennystats"])

# The kernels are a C library loaded through core ffi, so nothing in the
# package managers' native-module machinery builds it. This rule does:
# installing the package compiles libs/janet-num.c into the pinned
# ~/.local/lib/janet-num/libjn.so, which is where jennystats/num looks
# first. It rebuilds only when the source is newer, so repeated installs
# are cheap. The manual installer (libs/install-janet-num.sh) stays for
# vendored trees and for machines that install the module by hand.
(defn- shq
  [s]
  (string "'" (string/replace-all "'" "'\\''" s) "'"))

(defn- kernel-build []
  (def home (get (os/environ) "HOME"))
  (unless home (error "janet-num: HOME is not set, cannot place libjn.so"))
  (def dir (string home "/.local/lib/janet-num"))
  (def so (string dir "/libjn.so"))
  (def src "libs/janet-num.c")
  (def so-st (try (os/stat so) ([_] nil)))
  (def src-st (os/stat src))
  (def up-to-date (and so-st src-st
                       (>= (get so-st :modified) (get src-st :modified))))
  (if up-to-date
    (print "janet-num: kernel up to date at " so)
    (do
      (def cc (or (get (os/environ) "CC") "cc"))
      (def code
        (os/execute ["/bin/sh" "-c"
                     (string "mkdir -p " (shq dir)
                             " && " (shq cc) " -O2 -Wall -Wextra -shared -fPIC"
                             " -o " (shq so) " " (shq src))] :p))
      (unless (= 0 code)
        (errorf "janet-num: kernel build failed (%s exit %d) - install a C compiler"
                cc code))
      (unless (os/stat so) (error "janet-num: kernel build produced no libjn.so"))
      (print "janet-num: built " so))))

# jpm owns the "build" target and appends to "install"; spork/declare-cc
# (what janet-pm runs project.janet under) builds its :build graph. The
# discriminator is jpm's :manifest dynamic, set by its declare-project.
(if (dyn :manifest)
  (task "install" [] (kernel-build))
  (rule :build ["libs/janet-num.c"] (kernel-build)))
