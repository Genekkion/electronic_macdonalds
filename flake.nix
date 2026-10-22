{
    description = "Zig environment";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
        flake-utils.url = "github:numtide/flake-utils";
        zig.url = "github:mitchellh/zig-overlay";
    };

    outputs = { self, 
        nixpkgs, flake-utils,
        zig 
        }: 

        flake-utils.lib.eachDefaultSystem (
            system: let pkgs = import nixpkgs {
                inherit system;
                overlay = [
                    zig.overlay
                ];
            };
            in {
                devShells.default = pkgs.mkShell {
                    buildInputs = [
                        pkgs.zig
                    ];
                };
            }
        );
}
