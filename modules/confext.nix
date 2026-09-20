{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.systemd.confext;

  settingsFormat = pkgs.formats.systemd { };
  confextConf = settingsFormat.generate "confext.conf" cfg.settings;

  mutable = cfg.settings.ConfExt.Mutable;

  # The write routing directory systemd looks for. Making it a symlink to the
  # hierarchy itself turns the hierarchy into the overlay's upper layer.
  routingDirectory = "/var/lib/extensions.mutable/etc";
in
{
  options.systemd.confext = {
    enable =
      lib.mkEnableOption ''
        systemd-confext, which merges configuration extension images found in
        {file}`/var/lib/confexts` into {file}`/etc` using overlayfs at boot.

        Images installed at runtime are not part of the system closure: install
        them with {manpage}`systemd-confext(8)` or {manpage}`importctl(1)`.

        This is only supported together with
        {option}`system.etc.confext.enable`, which builds {file}`/etc` itself
        as an image and turns this on
      ''
      // {
        default = config.system.etc.confext.enable;
        defaultText = lib.literalExpression "config.system.etc.confext.enable";
      };

    initrd.enable =
      lib.mkEnableOption ''
        systemd-confext in the initrd, which merges configuration extension
        images found in the initrd's own search directories into the initrd's
        own {file}`/etc`. In the initrd systemd looks in {file}`/run/confexts`,
        {file}`/var/lib/confexts`, {file}`/usr/local/lib/confexts` and the
        {file}`/.extra/confext` and {file}`/.extra/global_confext` directories
        {manpage}`systemd-stub(7)` fills from the EFI system partition - all of
        them inside the initrd, and not on the root filesystem.

        This extends the configuration of the initrd itself, and has nothing to
        do with the {file}`/etc` of the system it boots: images for that go to
        {file}`/var/lib/confexts` on the root filesystem, where
        {option}`systemd.confext.enable` picks them up. Images from the EFI
        system partition in particular only ever configure the initrd: systemd
        does not hand them over to the system.

        The initrd's {file}`/etc` is kept writable (`Mutable=yes`), since NixOS
        writes to it while booting
      ''
      // {
        default = cfg.enable;
        defaultText = lib.literalExpression "config.systemd.confext.enable";
      };

    initrd.imagePolicy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "root=verity+signed+encrypted+unprotected+absent:=ignore";
      description = ''
        Image policy for the images merged into the initrd's own {file}`/etc`,
        see {manpage}`systemd.image-policy(7)`.

        systemd applies a stricter policy of its own to the images
        {manpage}`systemd-stub(7)` picks up from the EFI system partition,
        under {file}`/.extra`: they have to be signed disk images, since the
        partition they come from is not trusted. Unsigned images from there
        need a policy that accepts them, for instance the one systemd uses for
        configuration extensions everywhere else, in the example above.
      '';
    };

    noExec = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to mount the merged {file}`/etc` with `noexec`.

        systemd defaults this to `true`, but NixOS executes files below
        {file}`/etc` - systemd generators in {file}`/etc/systemd/system-generators`,
        for instance - so the default here is `false`.
      '';
    };

    mutableDirectory = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "/etc"
          routingDirectory
        ]
      );
      default =
        if
          lib.elem mutable [
            "auto"
            "yes"
          ]
        then
          "/etc"
        else if
          lib.elem mutable [
            "import"
            "ephemeral-import"
          ]
        then
          routingDirectory
        else
          null;
      defaultText = lib.literalMD ''
        `"/etc"` for `auto` and `yes`, {file}`/var/lib/extensions.mutable/etc`
        for `import` and `ephemeral-import`, `null` otherwise
      '';
      example = routingDirectory;
      description = ''
        Where writes to the merged {file}`/etc` are routed, which is also the
        directory `import` and `ephemeral-import` merge in.

        systemd always looks for {file}`/var/lib/extensions.mutable/etc`, so
        this option is what that path is made to be:

        - `"/etc"`, the hierarchy itself, makes the underlying {file}`/etc` the
          overlay's upper layer. Writes land where they would without any
          extension merged, which is what keeps NixOS activation and services
          writing to {file}`/etc` working.
        - {file}`/var/lib/extensions.mutable/etc` is created as a directory of
          its own, so writes are kept apart from the underlying {file}`/etc`,
          which becomes the overlay's bottom layer.
        - `null` creates nothing. With `Mutable=auto` that means an immutable
          {file}`/etc`; with `Mutable=yes` systemd creates the directory
          itself.

        Pointing this at {file}`/etc` with `Mutable=import` or
        `ephemeral-import` is an error: systemd refuses to import a hierarchy
        into itself.
      '';
    };

    # Where writes to the merged /etc end up between reboots, if anywhere.
    # Overlayfs whiteouts and opaque markers live there too.
    upperDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      internal = true;
      readOnly = true;
      default =
        if !cfg.writable || !cfg.persistent then
          null
        else if mutable == "yes" && cfg.mutableDirectory == null then
          routingDirectory
        else
          cfg.mutableDirectory;
      description = "Upper layer of the merged {file}`/etc`, if it has a persistent one.";
    };

    # Whether /etc can be written to at all while extensions are merged.
    writable = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      default =
        !(lib.elem mutable [
          null
          "no"
          "import"
        ])
        && !(mutable == "auto" && cfg.mutableDirectory == null);
      description = "Whether the merged {file}`/etc` is writable.";
    };

    # Whether writes to /etc survive an unmerge.
    persistent = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      default =
        !(lib.elem mutable [
          "ephemeral"
          "ephemeral-import"
        ]);
      description = "Whether writes to the merged {file}`/etc` outlive it.";
    };

    settings.ConfExt = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf settingsFormat.lib.types.atom;
        options = {
          Mutable = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "no"
                "yes"
                "auto"
                "import"
                "ephemeral"
                "ephemeral-import"
              ]
            );
            default = "auto";
            description = ''
              Mutability of the merged {file}`/etc`, as in
              {manpage}`systemd-sysext(8)`:

              - `auto` routes writes to {option}`systemd.confext.mutableDirectory`
                if it exists, and leaves {file}`/etc` read-only if it does not.
              - `yes` does the same but creates the directory when it is
                missing.
              - `no` leaves {file}`/etc` read-only.
              - `import` leaves {file}`/etc` read-only and merges
                {option}`systemd.confext.mutableDirectory` in on top of the
                extensions.
              - `ephemeral` makes {file}`/etc` writable through a directory on
                {file}`/run`, so writes are gone once extensions are unmerged.
              - `ephemeral-import` does both.

              The default routes writes to the underlying {file}`/etc`, which
              then acts as the overlay's upper layer: it keeps working for
              NixOS activation and for services that write to {file}`/etc`, at
              the price of files there taking precedence over files of the same
              name in extensions. See {option}`systemd.confext.mutableDirectory`
              for the other arrangements.

              With `system.etc.confext.enable`, a mode that makes {file}`/etc`
              read-only or ephemeral needs the users of the system to be
              managed by something that does not write to {file}`/etc`; the
              module asserts on it.
            '';
          };

          ImagePolicy = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Image policy applied to disk image based extensions.";
          };
        };
      };
      default = { };
      description = ''
        Settings written to the `[ConfExt]` section of
        {file}`/etc/systemd/confext.conf`. See {manpage}`confext.conf(5)`.

        Note that these are only read once {file}`/etc` is readable, so the
        units defined here pass the equivalent command line options instead.
        The file is written so that {command}`systemd-confext` invoked by hand
        behaves the same way.
      '';
    };

    # Command line flags matching `settings`, for callers that cannot rely on
    # /etc/systemd/confext.conf being readable - the initrd, and anything
    # running while /etc is unmerged.
    flags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      readOnly = true;
      default = (
        lib.optional (mutable != null) "--mutable=${mutable}"
        ++ lib.optional (
          cfg.settings.ConfExt.ImagePolicy != null
        ) "--image-policy=${cfg.settings.ConfExt.ImagePolicy}"
        ++ [ "--noexec=${lib.boolToString cfg.noExec}" ]
      );
      description = "Command line equivalent of {option}`systemd.confext.settings`.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          # systemd-confext on a classic /etc would put the files NixOS
          # manages in the upper layer, where images cannot override them, and
          # the activation that prepares /etc for merging would not run.
          assertion = cfg.enable == config.system.etc.confext.enable;
          message = ''
            systemd.confext.enable is only supported together with
            system.etc.confext.enable, which enables it.
          '';
        }
      ];
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion =
            lib.elem mutable [
              "import"
              "ephemeral-import"
            ]
            -> cfg.mutableDirectory != "/etc";
          message = ''
            systemd.confext.settings.ConfExt.Mutable = "${toString mutable}" cannot
            import /etc into itself. Set systemd.confext.mutableDirectory to a
            directory outside /etc, or to null to import nothing.
          '';
        }
      ];

      environment.etc."systemd/confext.conf".source = confextConf;

      # Where images are installed at runtime.
      systemd.tmpfiles.settings.confext."/var/lib/confexts".d = {
        mode = "0755";
        user = "root";
        group = "root";
      };

      systemd.additionalUpstreamSystemUnits = [ "systemd-confext.service" ];

      systemd.services.systemd-confext = {
        wantedBy = [ "sysinit.target" ];
        # Picks up images installed at runtime. Activation takes care of the
        # image of the system itself, see system.etc.confext.
        serviceConfig.ExecReload = [
          ""
          "${config.systemd.package}/bin/systemd-confext ${lib.escapeShellArgs cfg.flags} refresh"
        ];
      };
    })

    (lib.mkIf cfg.initrd.enable {
      assertions = [
        {
          assertion = config.boot.initrd.systemd.enable;
          message = "systemd.confext.initrd.enable requires boot.initrd.systemd.enable.";
        }
      ];

      boot.initrd.availableKernelModules = [
        "loop"
        "overlay"
        "erofs"
        "squashfs"
      ];

      boot.initrd.systemd = {
        # systemd's own unit for merging extensions into the initrd, which
        # nothing pulls in by itself.
        additionalUpstreamUnits = [ "systemd-confext-initrd.service" ];
        storePaths = [ "${config.boot.initrd.systemd.package}/bin/systemd-confext" ];

        services.systemd-confext-initrd = {
          wantedBy = [ "initrd.target" ];
          serviceConfig.ExecStart = [
            ""
            # Mutable=yes so that the merged /etc keeps taking the writes the
            # initrd makes to it, and noexec off for the same reason as in the
            # system: NixOS puts executables below /etc.
            (lib.concatStringsSep " " (
              [
                "${config.boot.initrd.systemd.package}/bin/systemd-confext"
                "--mutable=yes"
                "--noexec=false"
              ]
              ++ lib.optional (cfg.initrd.imagePolicy != null) "--image-policy=${cfg.initrd.imagePolicy}"
              ++ [ "refresh" ]
            ))
          ];
        };
      };
    })
  ];

  meta.maintainers = with lib.maintainers; [ jmbaur ];
}
