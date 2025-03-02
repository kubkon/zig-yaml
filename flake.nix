{
  description = "Flake for developing zig-yaml";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
    # zls.url = "github:zigtools/zls"; TODO re-enable once it's migrated to new build.zig.zon changes
    poop.url = "github:kubkon/poop/nix";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@inputs:
    let
      # Our supported systems are the same supported systems as the Zig binaries
      systems = builtins.attrNames inputs.zig.packages;
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = inputs.zig.packages.${system}.master;
        # zls = inputs.zls.packages.${system}.default.overrideAttrs (old: {
        #   nativeBuildInputs = [ zig ];
        # });
        poop = inputs.poop.packages.${system}.default.overrideAttrs (old: {
          nativeBuildInputs = [ zig ];
        });

        linuxSpecific = pkgs.lib.optionals pkgs.stdenv.isLinux [ poop ];
      in
      rec {
        devShells.default = pkgs.mkShell {
          name = "zig-yaml";
          buildInputs = [
            zig
            # zls
          ] ++ linuxSpecific;
        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;
      }
    );
}
