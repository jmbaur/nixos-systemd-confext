# nixos-systemd-confext

**NOTE: this is alpha quality software, use with caution**

`/etc` as a [systemd-confext] image, instead of the symlink farm NixOS builds
at activation time.

This is the out-of-tree version of the `jared/systemd-confext` nixpkgs branch,
for use until that lands. It carries the branch's modules, `makeConfext`, tests
and `nixos-init` unchanged, plus the shims listed in
[Differences from the nixpkgs branch](#differences-from-the-nixpkgs-branch).

```nix
{
  inputs.nixos-systemd-confext.url = "github:OWNER/nixos-systemd-confext";

  outputs = { nixpkgs, nixos-systemd-confext, ... }: {
    nixosConfigurations.machine = nixpkgs.lib.nixosSystem {
      modules = [
        nixos-systemd-confext.nixosModules.default
        {
          nixpkgs.overlays = [ nixos-systemd-confext.overlays.default ];
          boot.initrd.systemd.enable = true;
          system.etc.confext.enable = true;
        }
      ];
    };
  };
}
```

This removes Perl from activation, and makes `/etc` a stack of images that
systemd knows how to manage: images installed at runtime in `/var/lib/confexts`
are layered on top of the files NixOS manages, and can override them.

Switching to such a configuration migrates a running machine, and needs no
reboot. Rolling back to an older generation puts the old `/etc` back.

## How it works

`/etc` is an overlayfs mount that systemd-confext assembles:

| layer | contents |
| --- | --- |
| upper (writable) | the underlying `/etc`: `passwd`, `machine-id`, `/etc/nixos`, whatever services and admins write |
| lower | images installed in `/var/lib/confexts`, highest name first |
| lower | `/run/confexts/.host.raw`, the image built from `environment.etc` |

- The image is built with `makeConfext`, and is part of the system closure.
  The toplevel describes it in its bootspec document.
- systemd's own `systemd-confext-sysroot.service` merges it from the initrd,
  before switch-root. The module extends the unit with a drop-in, and runs
  `etc-confext-sysroot` from `nixos-init` before it, which picks the image of
  the generation that was booted from `init=` on the kernel command line. The
  initrd does not depend on the image, and booting an older generation merges
  its `/etc`.
- Activation, including the one `nixos-enter` runs, uses `etc-confext-activate`
  from `nixos-init` to point `/run/confexts` at the image of the new generation
  and run `systemd-confext refresh`. A switch that does not change `/etc`
  leaves the merge alone.
- The system image is named `.host`, which sorts below any name that starts
  with a letter, a digit or `_`, so an image installed at runtime takes
  precedence over the files NixOS manages. It is the name systemd gives the
  host's own image, which systemd-sysupdated does not take for an image to
  update, so the host's transfers (`systemd.sysupdate.transfers`) can be in
  the image. A switch to a generation whose image has another name removes the
  running generation's image from `/run/confexts`.
- A file deleted from the merged `/etc` leaves an overlayfs whiteout in the
  upper layer. For the paths the `.host` image provides, the next switch or
  boot clears it, so NixOS-managed files come back. Any other deletion is kept.

`systemd.confext.enable`, which merges images installed at runtime, is only
supported together with `system.etc.confext.enable`, which enables it: on a
classic `/etc` the files NixOS manages would be in the upper layer, where no
image can override them.

## Mutability

`systemd.confext.settings.ConfExt.Mutable` picks one of the mutability modes of
`systemd-sysext(8)`, and `systemd.confext.mutableDirectory` where writes to
`/etc` go:

| `Mutable` | `mutableDirectory` | `/etc` is | writes go to |
| --- | --- | --- | --- |
| `auto`, `yes` | `"/etc"` (default) | writable | the underlying `/etc`, which becomes the upper layer of the overlay |
| `auto`, `yes` | `/var/lib/extensions.mutable/etc` | writable | that directory; the underlying `/etc` stays below the images |
| `auto` | `null` | read-only | nowhere, until `/var/lib/extensions.mutable/etc` is created by hand |
| `yes` | `null` | writable | `/var/lib/extensions.mutable/etc`, which systemd creates itself |
| `no` | ignored | read-only | nowhere |
| `import` | `/var/lib/extensions.mutable/etc` | read-only | nowhere; the directory is merged *above* the images instead |
| `ephemeral` | ignored | writable | a directory on `/run`, discarded when `/etc` is unmerged |
| `ephemeral-import` | `/var/lib/extensions.mutable/etc` | writable | as `ephemeral`, plus the directory merged above the images |

systemd only ever looks at `/var/lib/extensions.mutable/etc`, so that is the
only directory writes can be routed to besides `/etc` itself.

A mode that leaves `/etc` read-only, or that throws writes away, needs the
password files to live somewhere else: enable `systemd.sysusers.enable` or
`services.userborn.enable`, which then keep them in `/var/lib/nixos`.
`/etc/machine-id` becomes the empty placeholder systemd expects, so that it
keeps the machine id on `/run`.

A read-only `/etc` also stops anything else that writes there: `resolvconf`,
for instance, fails. `import` is the escape hatch for such files, since the
directory it merges sits above the images.

## Installing an image at runtime

```console
# cp motd.raw /var/lib/confexts/
# systemctl reload systemd-confext.service
```

`systemctl reload` is preferred over `systemd-confext refresh`, since the unit
passes the options NixOS needs, `--noexec=false` in particular. Images are
built with `pkgs.makeConfext`, which `overlays.default` adds (or
`nixos-systemd-confext.lib.makeConfext pkgs` without it):

```nix
pkgs.makeConfext {
  name = "motd";
  files = {
    "motd" = ./motd;
    "ssh/sshd_config.d/motd.conf" = {
      source = ./sshd-motd.conf;
      mode = "0400";
    };
  };
}
```

- `files` is keyed by the path below `/etc`. A value is a file to copy in, or
  an attribute set with the `source`, `mode`, `uid` and `gid` of
  `environment.etc`. Files are copied with mode `0444` unless they say
  otherwise.
- `format` is `"erofs"` (the default), `"squashfs"` or `"directory"`. Only a
  filesystem image can carry modes and ownership.
- `extensionRelease` becomes the image's `extension-release` file, and defaults
  to `{ ID = "_any"; }`, which merges on any host. Set
  `{ ID = "nixos"; VERSION_ID = "25.11"; }` to pin an image to a release.
- An image carries `/etc` and nothing else, so the build refuses one that
  references the Nix store (`allowedReferences = [ ]`), which rules out
  `mode = "symlink"` for anything but the image NixOS builds for its own
  `/etc`. `allowStoreReferences = true` lifts that, for images only ever used
  on machines built from the same closure.

## Extending a single unit's `/etc`

`ExtensionImages=` and `ExtensionDirectories=` from `systemd.exec(5)` overlay
an image's `etc/` on `/etc` inside one unit's mount namespace, and nowhere
else. This needs nothing from this module, only an image:

```nix
systemd.services.sshd.serviceConfig.ExtensionImages = [
  "-/var/lib/unit-confexts/sshd.raw.v"
];
```

- Keep such images out of `/var/lib/confexts`, where systemd-confext would
  merge them into the system's `/etc`.
- `sshd.raw.v` is a versioned directory, see `systemd.v(7)`: systemd picks the
  newest `sshd_VERSION.raw` inside it.
- `RefreshOnReload=extensions` cannot refresh a running unit's extensions when
  `/etc` is an image itself: systemd expects a plain directory below the
  unit's overlay. Restart the unit instead.
- An image named by its store path needs
  `"${image}:x-systemd.relax-extension-release-check"`, since systemd insists
  that the file is named after its `extension-release` file.

## Extending the initrd's own `/etc`

`systemd.confext.initrd.enable`, on by default with `system.etc.confext`, has
systemd's `systemd-confext-initrd.service` merge images the initrd carries into
the initrd's own `/etc`. Images there need `CONFEXT_SCOPE = "initrd"` in their
`extensionRelease`, and have nothing to do with the `/etc` of the booted
system.

That includes the images `systemd-stub(7)` picks up from the EFI system
partition (`<uki>.efi.extra.d/*.confext.raw` and
`/loader/extensions/*.confext.raw`). systemd only ever merges those into the
initrd's `/etc`, and requires them to be signed unless
`systemd.confext.initrd.imagePolicy` says otherwise.

## Migrating from `system.etc.overlay`

The composefs based `/etc` of nixpkgs' `system.etc.overlay` kept its writes in
`/.rw-etc/upper`. The first time a system is activated or booted with
`system.etc.confext.enable` instead, a copy of that upper layer becomes the
underlying `/etc`. The directory that was hidden below the overlay is moved to
`/.rw-etc/etc.pre-confext`, and `/.rw-etc/upper` itself is left in place for a
rollback. The two options cannot be enabled together.

## Limitations

- `boot.initrd.systemd.enable` is required.
- Containers are not supported yet. They have no initrd and no bootspec to find
  the image in, and systemd-confext cannot open a disk image without a loop
  device, which containers do not have.
- In the default mode, the underlying `/etc` wins over the images. A file
  written there shadows the NixOS-managed file of the same name from then on.
  Routing writes to a directory of their own puts the underlying `/etc` below
  the images instead.
- `/etc` is briefly the bare underlying directory while a switch that changes
  it is refreshed: systemd-confext unmerges the old overlay before it puts the
  new one in place.
- `environment.etc` entries that name their owner instead of setting `uid` and
  `gid` are owned by root, since names cannot be resolved when the image is
  built.

## Differences from the nixpkgs branch

The branch changes a few nixpkgs modules and packages, which a module cannot
do from outside. Instead:

- `makeConfext` and the patched `nixos-init` come from a nixpkgs overlay,
  `overlays.default`, as they are packages on the branch. There is only one
  `nixos-init`. Apply it to the `pkgs`
  of the system, with `nixpkgs.overlays` or wherever `pkgs` is created (a
  module cannot add an overlay to read-only `pkgs`); the module asserts that it
  is there. The patch, `pkgs/nixos-init/confext.patch`, is `git diff master` of
  `pkgs/by-name/ni/nixos-init` on the branch, without `Cargo.lock` and without
  removing `src/find_etc.rs`, which the package removes itself since it differs
  between nixpkgs releases. The binaries the patch removes, `find-etc` and
  `clear-etc-opaque`, stay as names, since nixpkgs puts `find-etc` into every
  systemd initrd.
- `systemd-sysusers` and `userborn` decide where the password files go by
  looking at `system.etc.overlay`. The module points them at `/var/lib/nixos`
  itself when `/etc` cannot keep them.
- The `nixos-enter` in nixpkgs binds the host's `resolv.conf` into `/etc`
  before activating, where the merged `/etc` hides it, and makes every mount
  private, which keeps the merge from propagating back. Activation works around
  both when it runs under `nixos-enter`.
- `system.etc.overlay.enable` is not an alias, and `system.etc.overlay.mutable`
  does not map to `Mutable = "no"`: nixpkgs still has its own options by those
  names.

## Tests

```console
nix build .#checks.x86_64-linux.etc                # /etc from an image
nix build .#checks.x86_64-linux.mutable            # every mutability mode
nix build .#checks.x86_64-linux.confext            # images installed at runtime, and the initrd's /etc
nix build .#checks.x86_64-linux.extension-images   # images attached to a unit
nix build .#checks.x86_64-linux.classic-migration  # from the setup-etc.pl /etc
nix build .#checks.x86_64-linux.overlay-migration  # from the composefs /etc
nix build .#checks.x86_64-linux.nixos-init         # nixos-init and its unit tests
```

[systemd-confext]: https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html
