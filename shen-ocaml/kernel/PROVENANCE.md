# Kernel provenance

The 23 release KLambda files in this directory are the ShenOSKernel 43.1
release artifact. The release archive does not contain `compiler.kl`; that
CL-specific backend was removed from the OCaml port's kernel and generation
lists.

- Release tag: `shen-43.1`
- Release commit: `715824a52b55e9c81a9501df8548ff3edd8411f5`
- Release archive SHA-256: `900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`
- `(version)` is `"43.1"`, set by `shen.initialise` in `init.kl`.

The OCaml host exposes the 43.1 public character stream API
`char-stream?`, `read-unit-string`, and `write-string`. Its current streams
are byte-oriented, so the capability predicate returns `false` and the two
character operations report explicit unsupported errors.
