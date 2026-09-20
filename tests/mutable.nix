# Every mutability mode of systemd.confext. Each mode gets a machine of its
# own, since what the modes differ in is what is left of /etc after a reboot.
{ lib, ... }:
let
  routingDirectory = "/var/lib/extensions.mutable/etc";

  mkNode =
    confext:
    { ... }:
    {
      boot.initrd.systemd.enable = true;
      system.etc.confext.enable = true;
      systemd.confext = confext;

      # A read-only or ephemeral /etc cannot keep the password files, so they
      # live outside it in every mode alike.
      systemd.sysusers.enable = true;

      environment.etc = {
        "managed-file".text = "nixos";
        "shadowed".text = "nixos";
      };
    };
in
{
  name = "systemd-confext-mutable";

  meta.maintainers = with lib.maintainers; [ jmbaur ];

  nodes = {
    # The default: writes go to the underlying /etc, which is the upper layer.
    auto = mkNode { };

    # Writes kept apart from the underlying /etc, which is the bottom layer.
    auto_routed = mkNode { mutableDirectory = routingDirectory; };

    # auto without a directory to route writes to is read-only.
    auto_readonly = mkNode { mutableDirectory = null; };

    yes = mkNode { settings.ConfExt.Mutable = "yes"; };

    # yes without a directory has systemd create one.
    yes_created = mkNode {
      settings.ConfExt.Mutable = "yes";
      mutableDirectory = null;
    };

    no = {
      imports = [ (mkNode { settings.ConfExt.Mutable = "no"; }) ];
      # The classic resolvconf writes to /etc and fails there, which makes
      # switch-to-configuration exit uncleanly. systemd-resolved keeps its
      # state on /run instead.
      networking.useNetworkd = true;
      services.resolved.enable = true;
      specialisation.imported.configuration.systemd.confext.settings.ConfExt.Mutable =
        lib.mkForce "import";
    };

    imported = mkNode { settings.ConfExt.Mutable = "import"; };

    ephemeral = mkNode { settings.ConfExt.Mutable = "ephemeral"; };

    ephemeral_import = mkNode { settings.ConfExt.Mutable = "ephemeral-import"; };

    # Nothing passed to systemd, which then falls back to its own default.
    unset = mkNode { settings.ConfExt.Mutable = null; };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      def booted(m, mode):
          m.wait_for_unit("multi-user.target")
          m.succeed("findmnt --mountpoint /etc --types overlay")
          assert m.succeed("cat /etc/managed-file") == "nixos"
          # What systemd records about the merge, which shows that the mode
          # was passed on.
          origin = json.loads(m.succeed("cat /etc/.systemd-confext/origin"))
          assert origin["mutable"]["mode"] == mode, origin

      def reboot(m, mode):
          m.shutdown()
          m.start()
          booted(m, mode)

      def below(command):
          """Runs command against the /etc below the overlay, as /mnt/etc."""
          return f"mkdir -p /mnt && unshare --mount sh -c 'mount --bind / /mnt && {command}'"

      def read_only(m):
          error = m.fail("touch /etc/written 2>&1")
          assert "Read-only file system" in error, error
          m.fail("test -e /etc/written")

      def writes_persist(m, mode, upper):
          """Writes to the merged /etc land in upper and survive a reboot."""
          m.succeed("echo written > /etc/written")
          if upper == "/etc":
              assert m.succeed(below("cat /mnt/etc/written")) == "written\n"
          else:
              assert m.succeed(f"cat {upper}/written") == "written\n"
              # The underlying /etc is left alone.
              m.fail(below("test -e /mnt/etc/written"))
          reboot(m, mode)
          assert m.succeed("cat /etc/written") == "written\n"

      def writes_vanish(m, mode):
          """Writes to the merged /etc are gone after a reboot."""
          m.succeed("echo written > /etc/written")
          # Deleting a file NixOS manages only whites it out.
          m.succeed("rm /etc/managed-file")
          m.fail("test -e /etc/managed-file")
          m.fail(below("test -e /mnt/etc/written"))
          m.fail("test -e ${routingDirectory}/written")
          reboot(m, mode)
          m.fail("test -e /etc/written")

      with subtest("auto: writes land in the underlying /etc"):
          booted(auto, "auto")
          assert auto.succeed("readlink ${routingDirectory}") == "/etc\n"
          writes_persist(auto, "auto", "/etc")
          auto.shutdown()

      with subtest("auto: writes can be routed to a directory of their own"):
          booted(auto_routed, "auto")
          auto_routed.succeed("test -d ${routingDirectory} -a ! -L ${routingDirectory}")
          options = auto_routed.succeed("findmnt --mountpoint /etc --output OPTIONS --noheadings")
          assert "upperdir=" in options and "${routingDirectory}" in options, options
          # Even what systemd writes to /etc lands there.
          auto_routed.succeed("test -s ${routingDirectory}/machine-id")
          writes_persist(auto_routed, "auto", "${routingDirectory}")
          auto_routed.shutdown()

      with subtest("auto: /etc is read-only without a directory to route writes to"):
          booted(auto_readonly, "auto")
          auto_readonly.fail("test -e ${routingDirectory}")
          read_only(auto_readonly)
          # Creating the directory is all it takes to make /etc writable.
          auto_readonly.succeed("mkdir -m 0755 -p ${routingDirectory}")
          reboot(auto_readonly, "auto")
          writes_persist(auto_readonly, "auto", "${routingDirectory}")
          auto_readonly.shutdown()

      with subtest("yes: writes land in the underlying /etc"):
          booted(yes, "yes")
          assert yes.succeed("readlink ${routingDirectory}") == "/etc\n"
          writes_persist(yes, "yes", "/etc")
          yes.shutdown()

      with subtest("yes: systemd creates the directory writes are routed to"):
          booted(yes_created, "yes")
          yes_created.succeed("test -d ${routingDirectory} -a ! -L ${routingDirectory}")
          writes_persist(yes_created, "yes", "${routingDirectory}")
          yes_created.shutdown()

      with subtest("no: /etc is read-only, and the mutable directory is ignored"):
          booted(no, "no")
          read_only(no)
          assert no.succeed("readlink /etc/passwd") == "/var/lib/nixos/etc/passwd\n"
          no.succeed("getent passwd root")
          no.succeed(
              "mkdir -m 0755 -p ${routingDirectory}",
              "echo imported > ${routingDirectory}/shadowed",
          )
          reboot(no, "no")
          assert no.succeed("cat /etc/shadowed") == "nixos"

      with subtest("no: switching to import merges the directory in"):
          no.succeed("${nodes.no.system.build.toplevel}/specialisation/imported/bin/switch-to-configuration test")
          assert no.succeed("cat /etc/shadowed") == "imported\n"
          read_only(no)
          no.succeed("getent passwd root")
          no.shutdown()

      with subtest("import: the mutable directory is merged on top, read-only"):
          booted(imported, "import")
          imported.succeed("test -d ${routingDirectory} -a ! -L ${routingDirectory}")
          imported.succeed("echo imported > ${routingDirectory}/shadowed")
          reboot(imported, "import")
          # Above the image of the system.
          assert imported.succeed("cat /etc/shadowed") == "imported\n"
          read_only(imported)
          imported.shutdown()

      with subtest("ephemeral: /etc is writable, but forgets writes"):
          booted(ephemeral, "ephemeral")
          ephemeral.fail("test -e ${routingDirectory}")
          writes_vanish(ephemeral, "ephemeral")
          ephemeral.shutdown()

      with subtest("ephemeral-import: the mutable directory is merged on top, writes are forgotten"):
          booted(ephemeral_import, "ephemeral-import")
          ephemeral_import.succeed("echo imported > ${routingDirectory}/shadowed")
          reboot(ephemeral_import, "ephemeral-import")
          assert ephemeral_import.succeed("cat /etc/shadowed") == "imported\n"
          # Changing an imported file leaves the directory it came from alone.
          ephemeral_import.succeed("echo changed > /etc/shadowed")
          assert ephemeral_import.succeed("cat ${routingDirectory}/shadowed") == "imported\n"
          writes_vanish(ephemeral_import, "ephemeral-import")
          assert ephemeral_import.succeed("cat /etc/shadowed") == "imported\n"
          ephemeral_import.shutdown()

      with subtest("unset: systemd's own default is a read-only /etc"):
          booted(unset, "no")
          unset.fail("grep -q '^Mutable' /etc/systemd/confext.conf")
          read_only(unset)
          unset.shutdown()
    '';
}
