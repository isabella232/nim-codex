import std/os

if defined(release):
  switch("nimcache", joinPath(currentSourcePath.parentDir, "nimcache/release/$projectName"))
else:
  switch("nimcache", joinPath(currentSourcePath.parentDir, "nimcache/debug/$projectName"))

if defined(windows):
  # disable timestamps in Windows PE headers - https://wiki.debian.org/ReproducibleBuilds/TimestampsInPEBinaries
  switch("passL", "-Wl,--no-insert-timestamp")
  # increase stack size
  switch("passL", "-Wl,--stack,8388608")
  # https://github.com/nim-lang/Nim/issues/4057
  --tlsEmulation:off
  if defined(i386):
    # set the IMAGE_FILE_LARGE_ADDRESS_AWARE flag so we can use PAE, if enabled, and access more than 2 GiB of RAM
    switch("passL", "-Wl,--large-address-aware")

  # The dynamic Chronicles output currently prevents us from using colors on Windows
  # because these require direct manipulations of the stdout File object.
  switch("define", "chronicles_colors=off")

# This helps especially for 32-bit x86, which sans SSE2 and newer instructions
# requires quite roundabout code generation for cryptography, and other 64-bit
# and larger arithmetic use cases, along with register starvation issues. When
# engineering a more portable binary release, this should be tweaked but still
# use at least -msse2 or -msse3.

if defined(disableMarchNative):
  if defined(i386) or defined(amd64):
    switch("passC", "-mssse3")
elif defined(macosx) and defined(arm64):
  # Apple's Clang can't handle "-march=native" on M1: https://github.com/status-im/nimbus-eth2/issues/2758
  switch("passC", "-mcpu=apple-a14")
  # TODO: newer Clang >=15.0 can: https://github.com/llvm/llvm-project/commit/fcca10c69aaab539962d10fcc59a5f074b73b0de
else:
  switch("passC", "-march=native")
  if defined(windows):
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=65782
    # ("-fno-asynchronous-unwind-tables" breaks Nim's exception raising, sometimes)
    switch("passC", "-mno-avx512vl")

--tlsEmulation:off
--threads:on
--opt:speed
--excessiveStackTrace:on
# enable metric collection
--define:metrics
# for heap-usage-by-instance-type metrics and object base-type strings
--define:nimTypeNames

switch("define", "withoutPCRE")

# the default open files limit is too low on macOS (512), breaking the
# "--debugger:native" build. It can be increased with `ulimit -n 1024`.
if not defined(macosx):
  # add debugging symbols and original files and line numbers
  --debugger:native
  if not (defined(windows) and defined(i386)) and not defined(disable_libbacktrace):
    # light-weight stack traces using libbacktrace and libunwind
    --define:nimStackTraceOverride
    switch("import", "libbacktrace")

--define:nimOldCaseObjects # https://github.com/status-im/nim-confutils/issues/9

# `switch("warning[CaseTransition]", "off")` fails with "Error: invalid command line option: '--warning[CaseTransition]'"
switch("warning", "CaseTransition:off")

# The compiler doth protest too much, methinks, about all these cases where it can't
# do its (N)RVO pass: https://github.com/nim-lang/RFCs/issues/230
switch("warning", "ObservableStores:off")

# Too many false positives for "Warning: method has lock level <unknown>, but another method has 0 [LockLevel]"
switch("warning", "LockLevel:off")

switch("define", "libp2p_pki_schemes=secp256k1")
#TODO this infects everything in this folder, ideally it would only
# apply to codex.nim, but since codex.nims is used for other purpose
# we can't use it. And codex.cfg doesn't work
switch("define", "chronicles_sinks=textlines[dynamic],json[dynamic]")

# begin Nimble config (version 1)
when system.fileExists("nimble.paths"):
  include "nimble.paths"
# end Nimble config
