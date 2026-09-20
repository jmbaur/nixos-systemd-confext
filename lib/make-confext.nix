# Builds a systemd-confext image: a plain directory or a raw filesystem image
# (erofs/squashfs) whose root contains `etc/`. See systemd-sysext(8).
#
# Tested by nixos/tests/systemd-confext.nix.
#
# Files take the options of `environment.etc`, so a NixOS configuration's
# `/etc` can be turned into an image as is. Only a filesystem image can carry
# file modes and ownership; the Nix store cannot, so a directory image is
# limited to symlinks and world-readable files owned by root.
{
  lib,
  runCommand,
  erofs-utils,
  squashfsTools,
  fakeroot,
}:

{
  name,
  # Files of the image, by path relative to etc/:
  #   { "motd" = ./motd; "ssh/key" = { source = ./key; mode = "0400"; }; }
  # A value is a source, or `{ source, mode ? "0444", uid ? 0, gid ? 0 }`.
  # `mode` is an octal mode for a copy, or "symlink" or "direct-symlink" for
  # a symlink to `source`, which needs `allowStoreReferences` when `source` is
  # in the store. A `source` containing `*` is globbed into a directory of
  # symlinks.
  files ? { },
  # Contents of etc/extension-release.d/extension-release.<name>. systemd only
  # merges an image whose `ID=` matches the host's os-release, and whose
  # `CONFEXT_LEVEL=` or, if that is unset, `VERSION_ID=` does too, unless `ID=`
  # is `_any`. The default merges on any host; set
  # `{ ID = "nixos"; VERSION_ID = "25.11"; }` to pin an image to a release.
  extensionRelease ? {
    ID = "_any";
  },
  # One of "erofs", "squashfs" or "directory".
  format ? "erofs",
  # Whether the image may point into the Nix store. An image is installed on
  # machines that do not have the store it was built from, and a confext can
  # only carry `/etc`, never the store paths `/etc` refers to, so the build
  # refuses store references unless they are asked for. The image NixOS builds
  # for its own `/etc` is the exception: it ships with the system closure.
  allowStoreReferences ? false,
}:

let
  normalize =
    target: value:
    let
      file = if lib.isAttrs value && !lib.isDerivation value then value else { source = value; };
    in
    {
      inherit target;
      source = "${file.source}";
      mode = file.mode or "0444";
      uid = file.uid or 0;
      gid = file.gid or 0;
    };

  allEntries = lib.mapAttrsToList normalize files;

  # os-release(5) syntax, which extension-release files share.
  releaseFile = lib.generators.toKeyValue {
    mkKeyValue = lib.generators.mkKeyValueDefault {
      mkValueString = v: ''"${lib.escape [ "\\" "\"" "$" "`" ] (toString v)}"'';
    } "=";
  } extensionRelease;

  # Runs under fakeroot, which records the modes and ownership the files ask
  # for while leaving them readable to the build user, so mkfs can store them.
  script = ''
    set -euo pipefail

    mkdir -p root/etc/extension-release.d
    printf '%s' ${lib.escapeShellArg releaseFile} \
      > root/etc/extension-release.d/extension-release.${name}

    makeEntry() {
      local source="$1" target="$2" mode="$3" uid="$4" gid="$5"
      local dest="root/etc/$target"
      mkdir -p "$(dirname "$dest")"

      if [[ "$source" == *'*'* ]]; then
        # Glob the source into a directory of symlinks, like environment.etc.
        mkdir -p "$dest"
        for fn in $source; do
          ln -s "$fn" "$dest/$(basename "$fn")"
        done
      elif [[ "$mode" == symlink || "$mode" == direct-symlink ]]; then
        ln -s "$source" "$dest"
      else
        cp -rLT --no-preserve=mode,ownership "$source" "$dest"
        find "$dest" -type d -exec chmod 0755 {} +
        find "$dest" ! -type d -exec chmod "$mode" {} +
      fi
      chown -h -R "$uid:$gid" "$dest"
    }

    ${lib.concatMapStringsSep "\n" (
      e:
      lib.escapeShellArgs [
        "makeEntry"
        e.source
        e.target
        e.mode
        (toString e.uid)
        (toString e.gid)
      ]
    ) allEntries}
  ''
  + {
    directory = ''mv root "$out"'';
    # A filesystem UUID derived from what the image holds, so that images
    # build reproducibly, and the same contents always make the same image no
    # matter which store paths they were copied from. It covers the path,
    # type, mode, ownership, symlink target and contents of everything in it,
    # as fakeroot recorded them.
    erofs = ''
      uuid=$(
        cd root &&
          find . -print0 | LC_ALL=C sort -z |
          tar --create --file=- --null --no-recursion --files-from=- \
            --format=gnu --numeric-owner --mtime=@0 |
          sha256sum |
          sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/'
      )
      mkfs.erofs --quiet -T0 -U "$uuid" "$out" root
    '';
    # Uncompressed, so that Nix finds the store paths that allowedReferences
    # is there to refuse.
    squashfs = ''mksquashfs root "$out" -noappend -no-xattrs -reproducible -quiet -no-compression'';
  }
  .${format};
in

assert lib.assertMsg (lib.elem format [
  "directory"
  "erofs"
  "squashfs"
]) "makeConfext: unknown format '${format}'";
assert lib.assertMsg (
  builtins.match "[A-Za-z0-9_.~-]+" name != null
) "makeConfext: invalid confext name '${name}'";
assert lib.assertMsg (
  format != "directory" || lib.all (e: e.uid == 0 && e.gid == 0) allEntries
) "makeConfext: a directory image cannot carry file ownership, use format = \"erofs\"";

runCommand "confext-${name}${lib.optionalString (format != "directory") ".raw"}"
  (
    {
      nativeBuildInputs = [
        fakeroot
      ]
      ++ lib.optional (format == "erofs") erofs-utils
      ++ lib.optional (format == "squashfs") squashfsTools;
      inherit script;
      passAsFile = [ "script" ];
    }
    // lib.optionalAttrs (!allowStoreReferences) {
      # A confext is applied on machines that were not built from this store,
      # so nothing in it may point into the store: a symlink into it dangles
      # there, and a path inside a file names something that is not installed.
      allowedReferences = [ ];
    }
  )
  ''
    fakeroot -- bash "$scriptPath"
  ''
