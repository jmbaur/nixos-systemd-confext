# The packages the nixpkgs branch this comes from adds or changes: makeConfext,
# and a nixos-init that prepares /etc for merging. There is one nixos-init, and
# the module checks that pkgs was created with this overlay.
final: prev: {
  makeConfext = final.callPackage ./lib/make-confext.nix { };

  nixos-init = final.callPackage ./pkgs/nixos-init/package.nix { inherit (prev) nixos-init; };
}
