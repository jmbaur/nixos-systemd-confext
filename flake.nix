{
  description = "NixOS support for systemd-confext configuration extension images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # One module, carrying both option trees: systemd.confext for images
      # installed at runtime, and system.etc.confext for /etc itself.
      nixosModules.default = ./modules;

      # makeConfext :: pkgs -> { name, files, extensionRelease, format, allowStoreReferences } -> derivation
      lib.makeConfext = pkgs: pkgs.callPackage ./lib/make-confext.nix { };

      # The packages the nixpkgs branch adds or changes, makeConfext and
      # nixos-init. The module needs it applied to pkgs.
      overlays.default = import ./overlay.nix;

      packages = forAllSystems (pkgs: {
        inherit (pkgs.extend self.overlays.default) nixos-init;
      });

      checks = forAllSystems (
        pkgs:
        let
          runTest =
            module:
            pkgs.testers.runNixOSTest {
              imports = [ module ];
              defaults = {
                imports = [ self.nixosModules.default ];
                nixpkgs.overlays = [ self.overlays.default ];
              };
              node.pkgsReadOnly = false;
            };
        in
        {
          confext = runTest ./tests/confext.nix;
          mutable = runTest ./tests/mutable.nix;
          extension-images = runTest ./tests/extension-images.nix;
          etc = runTest ./tests/etc.nix;
          classic-migration = runTest ./tests/classic-migration.nix;
          overlay-migration = runTest ./tests/overlay-migration.nix;
          nixos-init = self.packages.${pkgs.stdenv.hostPlatform.system}.nixos-init;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
