# nixos-init from nixpkgs, with the changes of the nixpkgs branch this comes
# from, which prepare /etc for merging a systemd-confext image. The patch is
# `git diff master` of pkgs/by-name/ni/nixos-init there, without Cargo.lock
# and without removing src/find_etc.rs, which differs between nixpkgs
# releases and is removed here instead.
{
  lib,
  rustPlatform,
  nixos-init,
}:

let
  # The branch adds rustix as a direct dependency. It is locked already, as a
  # dependency of pathrs, so no vendored crate changes, but buildRustPackage
  # insists that the lock file it vendored from is the one in the source.
  upstreamLockFile = builtins.readFile "${nixos-init.src}/Cargo.lock";
  lockFile =
    builtins.replaceStrings
      [ " \"pathrs\",\n \"serde\",\n" ]
      [ " \"pathrs\",\n \"rustix\",\n \"serde\",\n" ]
      upstreamLockFile;
in

assert lib.assertMsg (
  lockFile != upstreamLockFile
) "nixos-systemd-confext: the Cargo.lock of nixos-init changed, update pkgs/nixos-init/package.nix";

nixos-init.overrideAttrs (previousAttrs: {
  patches = (previousAttrs.patches or [ ]) ++ [ ./confext.patch ];

  cargoDeps = rustPlatform.importCargoLock { lockFileContents = lockFile; };

  postPatch = (previousAttrs.postPatch or "") + ''
    cp ${builtins.toFile "Cargo.lock" lockFile} Cargo.lock
    rm src/find_etc.rs
  '';

  # What the module checks for, since it cannot apply the overlay itself when
  # pkgs is read-only.
  passthru = previousAttrs.passthru // {
    systemdConfext = true;
  };

  # find-etc and clear-etc-opaque are gone, but stay as names: nixpkgs puts
  # find-etc into every systemd initrd. Only the composefs /etc runs them,
  # which the module does not allow together with a confext /etc.
  binaries = previousAttrs.binaries ++ [
    "etc-confext-activate"
    "etc-confext-sysroot"
  ];
})
