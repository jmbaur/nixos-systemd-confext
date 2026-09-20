# Builds /etc itself as a systemd-confext image.
#
# The image is part of the system closure and is deployed with the toplevel;
# the initrd and every switch-to-configuration point systemd-confext at the
# image of the generation they belong to and merge it. By default, the
# underlying /etc is the overlay's upper layer, so it stays writable and keeps
# everything that is not managed by NixOS, while images dropped into
# /var/lib/confexts at runtime layer on top of the NixOS-provided files.
#
# The preparation is done by nixos-init (etc-confext-sysroot in the initrd,
# before systemd-confext-sysroot.service merges /etc, and etc-confext-activate
# on activation), which reads what it needs to know about the image from the
# bootspec of the toplevel.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.system.etc.confext;
  confextCfg = config.systemd.confext;
  mutable = confextCfg.settings.ConfExt.Mutable;

  normalizeTarget =
    target:
    lib.concatStringsSep "/" (
      lib.filter (part: part != "" && part != ".") (lib.splitString "/" target)
    );

  etcFiles = lib.filterAttrs (_: f: f.enable) config.environment.etc;

  files =
    lib.mapAttrs' (
      _: f:
      lib.nameValuePair (normalizeTarget f.target) {
        inherit (f)
          source
          mode
          uid
          gid
          ;
      }
    ) etcFiles
    // {
      # nixpkgs points systemd at /etc/static/... for files it must not modify,
      # and a handful of modules reference paths below it directly.
      static = {
        source = "${config.system.build.etc}/etc";
        mode = "symlink";
      };
    };

  image = pkgs.makeConfext {
    inherit (cfg) name format;
    inherit files;
    # The system's own image is deployed with the toplevel, so the store it
    # points into is the one it is merged on.
    allowStoreReferences = true;
  };

  # Every path the image provides, leading directories included. Used to clear
  # overlayfs whiteouts and opaque markers that would hide them for good from
  # the upper layer. Other paths there are left alone.
  prefixesOf =
    target:
    let
      parts = lib.splitString "/" target;
    in
    lib.genList (i: lib.concatStringsSep "/" (lib.take (i + 1) parts)) (builtins.length parts);

  targets = pkgs.writeText "etc-confext-targets" (
    lib.concatLines (lib.unique (lib.concatMap prefixesOf (lib.attrNames files)))
  );

  # Entries that name an owner without giving a uid and a gid: the names
  # cannot be resolved when the image is built, so the ids win.
  namesOwner =
    name: id:
    !(lib.elem name [
      "+${toString id}"
      "root"
    ])
    && id == 0;
  namedOwners = lib.filter (
    f: f.mode != "symlink" && (namesOwner f.user f.uid || namesOwner f.group f.gid)
  ) (lib.attrValues etcFiles);

  # Patched by ../overlay.nix, which carries the preparation for merging /etc.
  nixos-init = config.system.nixos-init.package;

  util-linux = "${pkgs.util-linux}/bin";

  # systemd-confext-sysroot.service came with systemd 261. The nixpkgs branch
  # this comes from has it; for an older systemd, the out-of-tree shims below
  # define the unit as systemd 261 ships it.
  hasSysrootUnit = lib.versionAtLeast config.boot.initrd.systemd.package.version "261";

  # Where sysusers and userborn put the password files when /etc cannot keep
  # them. Both decide that by looking at system.etc.overlay, which says
  # nothing about a confext /etc, so they are pointed there from here.
  sysusersFilesLocation = "/var/lib/nixos/etc";
  sysusersFiles = [
    "passwd"
    "group"
    "shadow"
    "gshadow"
  ];
in
{
  options.system.etc.confext = {
    enable = lib.mkEnableOption ''
      building {file}`/etc` as a systemd-confext image instead of populating it
      with symlinks at activation time.

      The image is part of the system closure. It is merged in the initrd, and
      every {command}`switch-to-configuration` migrates {file}`/etc` to the
      image of the new generation. By default, the underlying {file}`/etc`
      remains the overlay's writable upper layer, and images installed in
      {file}`/var/lib/confexts` at runtime are layered in between
    '';

    name = lib.mkOption {
      readOnly = true;
      type = lib.types.str;
      default = ".host";
      description = ''
        Name of the system's configuration extension image.

        systemd orders extensions by name with the rules of
        {manpage}`systemd.version(7)` and lets the highest one win. The default
        sorts below every name that starts with a letter, a digit or `_`, so
        images installed at runtime can override files NixOS manages.

        It is also the name systemd gives the image of the host itself, which
        is what this image is: its {file}`/etc`. systemd-sysupdated takes
        every other image it discovers that carries transfers of its own in
        {file}`etc/sysupdate.d` for an image it is to update, so the transfers
        of the host ({option}`systemd.sysupdate.transfers`) would make it list
        a target of its own for an image of any other name, whose version it
        cannot tell, and then no target at all.
      '';
    };

    format = lib.mkOption {
      type = lib.types.enum [
        "erofs"
        "squashfs"
        "directory"
      ];
      default = "erofs";
      description = ''
        Format of the system's configuration extension image.

        A `directory` image needs no filesystem driver and can be inspected in
        the store, but the store cannot carry file modes or ownership, so
        {option}`environment.etc` entries that ask for them are not represented
        faithfully.
      '';
    };

    image = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = image;
      defaultText = lib.literalMD "the image built from {option}`environment.etc`";
      description = "The system's configuration extension image.";
    };

    # Consulted by the modules that write state to /etc, systemd-sysusers and
    # userborn, to put it somewhere else.
    immutable = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      default = cfg.enable && (!confextCfg.writable || !confextCfg.persistent);
      defaultText = lib.literalMD "whether writes to the merged {file}`/etc` are impossible or lost";
      description = ''
        Whether {file}`/etc` cannot keep state: it is read-only, or what is
        written to it does not survive a reboot.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.boot.initrd.systemd.enable;
            message = ''
              system.etc.confext.enable requires boot.initrd.systemd.enable: /etc
              has to be merged before the service manager of the system starts.
            '';
          }
          {
            # TODO: support containers. They have no initrd and no bootspec, and
            # systemd-confext cannot open a disk image without a loop device, which
            # containers do not have.
            assertion = !config.boot.isContainer;
            message = "system.etc.confext.enable is not supported in containers yet.";
          }
          {
            # nixpkgs' own composefs /etc, which this replaces in the nixpkgs
            # branch it comes from.
            assertion = !config.system.etc.overlay.enable;
            message = "system.etc.confext.enable and system.etc.overlay.enable are mutually exclusive.";
          }
          {
            assertion =
              (cfg.immutable && config.services.userborn.enable)
              -> (config.services.userborn.static || config.services.userborn.passwordFilesLocation != "/etc");
            message = ''
              An immutable /etc needs services.userborn.passwordFilesLocation to
              point outside /etc, or services.userborn.static to put the password
              files in the image.
            '';
          }
          {
            assertion = config.environment.etc ? "os-release";
            message = "system.etc.confext.enable requires environment.etc.\"os-release\", which systemd matches extension images against.";
          }
          {
            # update-users-groups.pl writes the password files to /etc with no way
            # to redirect it. systemd-sysusers and userborn both put them
            # somewhere else when /etc is immutable.
            assertion =
              !confextCfg.writable -> (config.systemd.sysusers.enable || config.services.userborn.enable);
            message = ''
              A read-only /etc (systemd.confext.settings.ConfExt.Mutable =
              "${toString mutable}") requires systemd.sysusers.enable or
              services.userborn.enable: the password files cannot be written to
              /etc.
            '';
          }
        ];

        warnings =
          lib.optional (namedOwners != [ ]) ''
            These environment.etc entries name their owner instead of giving a uid
            and a gid, which cannot be resolved when the /etc image is built. They
            will be owned by root: ${lib.concatMapStringsSep ", " (f: f.target) namedOwners}.
          ''
          ++
            lib.optional
              (!confextCfg.persistent && !(config.systemd.sysusers.enable || config.services.userborn.enable))
              ''
                systemd.confext.settings.ConfExt.Mutable = "${toString mutable}" throws
                away everything written to /etc when extensions are unmerged, password
                hashes in /etc/shadow included. Enable systemd.sysusers or
                services.userborn so that the password files live outside /etc.
              '';

        # s-t-c compares /etc/NIXOS to decide whether it is dealing with a NixOS
        # system; the classic activation creates it as a side effect.
        environment.etc.NIXOS.text = lib.mkDefault "";

        system.requiredKernelConfig =
          with config.lib.kernelConfig;
          [
            (isEnabled "OVERLAY_FS")
          ]
          ++ lib.optional (cfg.format == "erofs") (isEnabled "EROFS_FS")
          ++ lib.optional (cfg.format == "squashfs") (isEnabled "SQUASHFS");

        # An empty regular file means systemd will bind mount /run/machine-id on
        # top, and ConditionFirstBoot will be false (the file will never change,
        # so this makes sense). See machine-id(5) "First Boot Semantics". It also
        # serves as a target to bind mount an actually persistent machine-id onto.
        # A symlink doesn't work here since systemd-machine-id-commit checks
        # /etc/machine-id itself for being a mountpoint without following
        # symlinks, so it would never commit through a symlink.
        environment.etc.machine-id = lib.mkIf cfg.immutable (
          lib.mkDefault {
            text = "";
            mode = "0444";
          }
        );

        # The upstream unit has ConditionPathIsReadWrite=/etc, which is always
        # false here. Replace it with ConditionFirstBoot: with the empty
        # placeholder above first-boot is "no" and commit stays skipped, but when
        # a persistence module bind-mounts a writable file containing
        # "uninitialized" over /etc/machine-id, first-boot is "yes" once and
        # commit writes the generated ID through the bind mount.
        #
        # An empty Condition*= assignment resets *all* condition types, and this
        # attrset is serialised in key order, so the reset goes through
        # ConditionFirstBoot (sorts first) and we re-add the upstream
        # ConditionPathIsMountPoint afterwards.
        systemd.services.systemd-machine-id-commit.unitConfig = lib.mkIf cfg.immutable {
          ConditionFirstBoot = lib.mkDefault [
            ""
            "true"
          ];
          ConditionPathIsMountPoint = lib.mkDefault "/etc/machine-id";
        };

        systemd.services.systemd-confext = {
          # Only needed to take down the /etc of the earlier system.etc.overlay.
          path = [ pkgs.util-linux ];
          # Upstream only runs when a search directory has an image, and does
          # not count hidden files, which the default name is. The image is a
          # link into the store, which is not followed, as in the initrd.
          unitConfig.ConditionPathIsSymbolicLink = [
            "|/run/confexts/${cfg.name}.raw"
            "|/run/confexts/${cfg.name}"
          ];
          serviceConfig = {
            # The initrd merges /etc before switch-root, and the mount id systemd
            # records for the image changes across it, so a plain refresh here
            # would always find a change and take /etc apart again in the middle
            # of the boot. This refreshes only when /etc has not been merged with
            # the image of the running generation yet. Reloading the unit still
            # refreshes unconditionally, to pick up images installed at runtime.
            ExecStart = [
              ""
              "${nixos-init}/bin/etc-confext-activate ${config.systemd.package}/bin/systemd-confext /run/current-system"
            ];
            # /etc is the confext, so unmerging it on shutdown would take the
            # configuration away from everything that shuts down after it.
            ExecStop = [ "" ];
          };
        };

        # Everything nixos-init needs to know about the image of a generation,
        # which lets the initrd merge the /etc of the generation that was booted
        # without depending on it.
        boot.bootspec.extensions."org.nixos.nixos-init.v1".etc_confext = {
          inherit (cfg) name;
          image = "${image}";
          targets = "${targets}";
          inherit (confextCfg) flags;
          mutable_directory = confextCfg.mutableDirectory;
          upper_directory = confextCfg.upperDirectory;
        };

        system.systemBuilderCommands = ''
          ln -s ${image} $out/etc-confext
        '';

        boot.initrd.availableKernelModules = [
          "loop"
          "overlay"
        ]
        ++ lib.optional (cfg.format == "erofs") "erofs"
        ++ lib.optional (cfg.format == "squashfs") "squashfs";

        boot.initrd.systemd = {
          # systemd's own unit for merging configuration extensions into the root
          # filesystem before switch-root, which NixOS only extends with a drop-in.
          additionalUpstreamUnits = lib.optional hasSysrootUnit "systemd-confext-sysroot.service";

          storePaths = [
            "${config.boot.initrd.systemd.package}/bin/systemd-confext"
            "${nixos-init}/bin/etc-confext-sysroot"
          ];

          # Points systemd-confext at the image of the generation that was booted,
          # which only init= on the kernel command line says, and prepares the
          # root for it.
          services.nixos-etc-confext-prepare = {
            description = "Prepare /sysroot/etc for Merging";
            requiredBy = [ "systemd-confext-sysroot.service" ];
            before = [ "systemd-confext-sysroot.service" ];
            unitConfig = {
              DefaultDependencies = false;
              ConditionKernelCommandLine = "!systemd.confext=0";
              WantsMountsFor = [ "/sysroot/var" ];
              RequiresMountsFor = [
                "/sysroot/nix/store"
                "/sysroot/run"
              ];
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${nixos-init}/bin/etc-confext-sysroot";
            };
          };

          services.systemd-confext-sysroot = {
            requiredBy = [ "initrd-fs.target" ];
            unitConfig = {
              # Upstream only looks for images on the root filesystem. The image
              # of the generation is installed in /run/confexts, which the initrd
              # binds to /sysroot/run.
              ConditionDirectoryNotEmpty = "|/sysroot/run/confexts";
              # Which does not count hidden files, which the default name is.
              # The image is a link into the store, which does not resolve in
              # the initrd, where the store is below /sysroot.
              ConditionPathIsSymbolicLink = [
                "|/sysroot/run/confexts/${cfg.name}.raw"
                "|/sysroot/run/confexts/${cfg.name}"
              ];
              # Upstream merges before initrd-root-fs.target, which is too early
              # here: the image is in the store and the images an admin installs
              # are in /var, either of which can be a filesystem of its own that
              # is mounted from the root's fstab once the root itself is up.
              Before = [
                ""
                "initrd-fs.target"
                "shutdown.target"
              ];
              WantsMountsFor = [ "/sysroot/var" ];
              RequiresMountsFor = [
                "/sysroot/nix/store"
                "/sysroot/run"
              ];
            };
            serviceConfig = {
              # The os-release of the host lives in the image itself, so systemd
              # cannot read it from /sysroot/etc before the merge. It resolves this
              # path below /sysroot, where the system closure has it. It only
              # changes with the NixOS version, which the initrd depends on anyway.
              Environment = "SYSTEMD_OS_RELEASE=${config.environment.etc."os-release".source}";
              # Upstream's command, with the options that can only be passed on
              # the command line.
              ExecStart = [
                ""
                "${config.boot.initrd.systemd.package}/bin/systemd-confext --root=/sysroot ${lib.escapeShellArgs confextCfg.flags} refresh"
              ];
            };
          };
        };

        # Replaces the classic /etc activation. $systemConfig is the toplevel
        # being activated.
        #
        # The nixos-enter in nixpkgs binds the host's resolv.conf into the
        # underlying /etc before activating, where the merged /etc hides it, and
        # makes every mount private, which keeps the merge systemd-confext makes in
        # a namespace of its own from propagating back. The nixpkgs branch fixes
        # nixos-enter; out of tree, activation works around it.
        system.build.etcActivationCommands = lib.mkForce ''
          resolvConf=
          etcMount=
          if [ -n "''${IN_NIXOS_ENTER:-}" ]; then
            if ${util-linux}/mountpoint -q /etc/resolv.conf; then
              resolvConf=/run/nixos-etc-confext/resolv.conf
              install -D -m 0644 /dev/null "$resolvConf"
              ${util-linux}/mount --bind /etc/resolv.conf "$resolvConf"
              ${util-linux}/umount /etc/resolv.conf
              # nixos-enter creates an empty file to mount over when there is
              # none, which would shadow the image's resolv.conf for good.
              if [ ! -L /etc/resolv.conf ] && [ ! -s /etc/resolv.conf ]; then
                rm -f /etc/resolv.conf
              fi
            fi
            # Shared in a peer group of its own, which reaches no namespace
            # outside of this one.
            etcMount="$(${util-linux}/findmnt --noheadings --output TARGET --target /etc)"
            ${util-linux}/mount --make-shared "$etcMount"
          fi

          ${nixos-init}/bin/etc-confext-activate ${config.systemd.package}/bin/systemd-confext "$systemConfig"

          if [ -n "$etcMount" ]; then
            ${util-linux}/mount --make-private "$etcMount"
          fi
          if [ -n "$resolvConf" ]; then
            resolvConfTarget="$(realpath -m /etc/resolv.conf)"
            if ! { [ -e "$resolvConfTarget" ] || install -D -m 0644 /dev/null "$resolvConfTarget"; } ||
              ! ${util-linux}/mount --bind "$resolvConf" "$resolvConfTarget"; then
              echo "failed to bind the host's resolv.conf into /etc" >&2
            fi
            ${util-linux}/umount "$resolvConf"
            rm -rf /run/nixos-etc-confext
          fi
        '';
      }

      # systemd-confext-sysroot.service as systemd 261 ships it, for an older
      # systemd. What the branch part above sets extends it like a drop-in.
      (lib.mkIf (!hasSysrootUnit) {
        boot.initrd.systemd.services.systemd-confext-sysroot = {
          description = "Merge System Configuration Images into /sysroot/etc/";
          documentation = [ "man:systemd-confext-sysroot.service(8)" ];
          wantedBy = [ "initrd.target" ];
          wants = [
            "modprobe@loop.service"
            "modprobe@dm_mod.service"
          ];
          after = [
            "modprobe@loop.service"
            "modprobe@dm_mod.service"
            "sysroot.mount"
            "sysroot-usr.mount"
            "systemd-volatile-root.service"
          ];
          conflicts = [ "shutdown.target" ];
          unitConfig = {
            DefaultDependencies = false;
            ConditionCapability = "CAP_SYS_ADMIN";
            ConditionPathExists = "/etc/initrd-release";
            ConditionKernelCommandLine = "!systemd.confext=0";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };
      })

      # What nixpkgs' systemd-sysusers and userborn modules do for an immutable
      # /etc in the nixpkgs branch this comes from, and cannot know to do here.
      {
        assertions = [
          {
            # The packages the branch changes. A module cannot add an overlay
            # when pkgs is read-only, so they are left to whoever creates pkgs.
            assertion = pkgs.nixos-init.passthru.systemdConfext or false;
            message = ''
              system.etc.confext.enable needs the nixos-init of
              nixos-systemd-confext: create pkgs with its overlays.default, or
              add it to nixpkgs.overlays.
            '';
          }
        ];

        environment.etc = lib.mkIf (cfg.immutable && config.systemd.sysusers.enable) (
          lib.genAttrs sysusersFiles (file: {
            source = "${sysusersFilesLocation}/${file}";
            mode = "direct-symlink";
          })
        );

        services.userborn.passwordFilesLocation = lib.mkIf cfg.immutable (lib.mkDefault "/var/lib/nixos");

        systemd.services.systemd-sysusers.serviceConfig =
          lib.mkIf (cfg.immutable && config.systemd.sysusers.enable)
            {
              # The config file has to be named explicitly, systemd-sysusers does
              # not find it by itself once --root is given.
              ExecStart = [
                ""
                "${config.systemd.package}/bin/systemd-sysusers --root ${dirOf sysusersFilesLocation} /etc/sysusers.d/00-nixos.conf"
              ];
              # Keep the read-only bind mounts of immutable users on the files that
              # are actually written.
              ExecStartPre = lib.mkIf (!config.users.mutableUsers) (
                lib.mkForce (map (file: "-${util-linux}/umount ${sysusersFilesLocation}/${file}") sysusersFiles)
              );
              ExecStartPost = lib.mkIf (!config.users.mutableUsers) (
                lib.mkForce (
                  map (
                    file:
                    "${util-linux}/mount --bind -o ro ${sysusersFilesLocation}/${file} ${sysusersFilesLocation}/${file}"
                  ) sysusersFiles
                )
              );
            };
      }
    ]
  );

  meta.maintainers = [ lib.maintainers.jmbaur ];
}
