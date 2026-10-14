# project.janet - jpm package manifest for janet-num.
(declare-project
  :name "janet-num"
  :description "Small C kernels for Janet's numeric hot paths, via core ffi - no native module"
  :license "AGPL-3.0"
  :version "0.1.1"
  :dependencies ["https://github.com/jennystats/janet-kit"])

(declare-source
  :source ["janet-num.janet"])
