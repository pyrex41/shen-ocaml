{
  description = "shen-ocaml – Shen language port to OCaml";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ocamlPkgs = pkgs.ocamlPackages;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # OCaml toolchain
            ocamlPkgs.ocaml
            ocamlPkgs.dune_3
            ocamlPkgs.findlib
            ocamlPkgs.ocaml-lsp
            ocamlPkgs.ocamlformat

            # Libraries
            ocamlPkgs.cmdliner

            # Build tools
            pkgs.opam
            pkgs.pkg-config
          ];

          shellHook = ''
            echo "shen-ocaml dev shell"
            echo "  ocaml: $(ocaml -version)"
            echo "  dune:  $(dune --version)"
          '';
        };
      });
}
