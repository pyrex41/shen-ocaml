# ShenOSKernel 43.1 qualification receipt

This branch uses the community ShenOSKernel 43.1 release at commit
`715824a52b55e9c81a9501df8548ff3edd8411f5` (archive SHA256
`900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`).

## Toolchain and build

Runs used the pinned Nix development shell with OCaml 5.3.0 and Dune 3.20.2:

```text
/nix/var/nix/profiles/default/bin/nix --option eval-cache false develop \
  --no-update-lock-file --command bash -c 'dune test -j1'
```

The build completed with exit 0. Symbol, parser, interpreter, and codegen
tests passed. The AOT compiler generated all 24 kernel modules. The generated
top-level form counts were: `core` 68, `toplevel` 17, `sys` 119, `reader` 137,
`prolog` 97, `load` 16, `writer` 28, `macros` 32, `declarations` 12,
`types` 6, `t-star` 51, `sequent` 50, `track` 29, `dict` 16, `compiler` 52,
`stlib` 326, `init` 4, `extension-features` 5,
`extension-expand-dynamic` 11, `extension-launcher` 13,
`extension-programmable-pattern-matching` 17, `extension-namespaces` 12,
`extension-type-annotations` 8, and `yacc` 48.

## Native launcher probes

The native launcher was built and run from the project root. Its Shen 43.1
results were:

```text
(value *version*)                 => "43.1"
(version)                         => "43.1"
(char-stream? (stinput))          => false
(trap-error (read-unit-string ...) ...) => "read-unit-string: character streams unsupported"
(trap-error (write-string "x" ...) ...) => "write-string: character streams unsupported"
(fn +)                            => <closure>
(arity char-stream?)              => 1
(arity read-unit-string)          => 1
(arity write-string)              => 2
(package? shen)                   => true
(external shen)                   => external symbol list
(type (stinput))                  => <stream>
(let D (shen.dict 10) ... )       => (true 3 7 "num" "pair")
(42 then 42.0 lookup)             => distinct-key miss; count remains 1
(same key 42 replacement)         => count 1, value "b"
(0.0 then -0.0 lookup)             => "zero"
```

The dictionary probe stores and reads a symbol key (`foo`), numeric key (`42`),
and structural cons key (`(cons bar 1)`), then reports `shen.dict?`, count, and
all three values. The regression test also confirms that distinct `Int` and
`Float` keys remain distinct, equal keys replace in place, structural keys
preserve that distinction recursively, and signed zero remains reachable.
The public probes cover the 43.1 stream surface, callable metadata, package
membership, external package membership, stream type, and dictionary behavior.

## Canonical suite boundary

The canonical `test_kernel_shen_suite` gate was already disabled at the
pre-upgrade baseline `bbd8d44`, documented as a `read-from-string` hang. A
baseline control temporarily enabled that unchanged test and ran it from
`test/shen` with a 45-second bound. It exited `124` after primitive
initialization, without harness counts. The same procedure on this 43.1
branch, bounded at 120 seconds, also exited `124` after primitive
initialization and consumed CPU without harness counts.

This leaves canonical 154-suite qualification UNKNOWN for the existing
interpreter limitation. The comparison supplies no evidence of a 43.1
regression; the gate remains opt-in as it was before the upgrade.
