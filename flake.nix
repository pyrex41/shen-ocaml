{
  description = "shen-ocaml (unfinished) — Nix-managed OCaml development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { nixpkgs, ... }:
    let systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ]; each = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      packages = each (pkgs: let o = pkgs.ocamlPackages; in { toolchain = pkgs.buildEnv { name = "shen-ocaml-toolchain"; paths = [ o.ocaml o.dune_3 o.findlib o.cmdliner pkgs.opam ]; }; default = pkgs.buildEnv { name = "shen-ocaml-toolchain"; paths = [ o.ocaml o.dune_3 o.findlib o.cmdliner pkgs.opam ]; }; });
      devShells = each (pkgs: let o = pkgs.ocamlPackages; in { default = pkgs.mkShell { packages = [ o.ocaml o.dune_3 o.findlib o.cmdliner o.ocaml-lsp o.ocamlformat pkgs.opam ]; shellHook = "cd shen-ocaml"; }; });
    };
}
