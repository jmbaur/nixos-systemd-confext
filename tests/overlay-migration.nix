# Switching from the composefs /etc of the earlier system.etc.overlay to the
# configuration extension image that replaced it.
#
# The old implementation is gone, so the test sets up what it left behind at
# runtime by hand: an erofs image mounted at /run/nixos-etc-metadata, and an
# overlay of it on /etc whose writes go to /.rw-etc/upper.
{ lib, ... }:
{
  name = "activation-etc-overlay-migration";

  meta.maintainers = with lib.maintainers; [ jmbaur ];

  nodes.machine =
    { pkgs, ... }:
    {
      boot.initrd.systemd.enable = true;
      environment.systemPackages = [ pkgs.erofs-utils ];
      environment.etc = {
        "managed".text = "old";
        "deleted-by-admin".text = "provided by NixOS";
        "chmodded" = {
          text = "provided by NixOS";
          mode = "0644";
        };
      };

      specialisation.confext.configuration = {
        system.etc.confext.enable = true;
        environment.etc."managed".text = lib.mkForce "new";
      };
    };

  testScript =
    { nodes, ... }:
    let
      confext = "${nodes.machine.system.build.toplevel}/specialisation/confext";
    in
    # python
    ''
      machine.wait_for_unit("multi-user.target")

      with subtest("set up the composefs /etc of the old system.etc.overlay"):
          machine.succeed(
              # What stays hidden below the overlay.
              "echo hidden > /etc/hidden-file",
              # The metadata image carries what NixOS manages in /etc.
              "cp -a /etc/. /tmp/metadata",
              "rm /tmp/metadata/hidden-file",
              # What systemd and the activation wrote through the overlay is
              # in its upper layer.
              "mkdir -p /.rw-etc/upper /.rw-etc/work",
              "for f in machine-id passwd group shadow subuid subgid; do if [ -e /tmp/metadata/$f ]; then mv /tmp/metadata/$f /.rw-etc/upper/; fi; done",
              "mkfs.erofs --quiet /tmp/metadata.erofs /tmp/metadata",
              "mkdir /run/nixos-etc-metadata",
              "mount -t erofs -o loop,ro /tmp/metadata.erofs /run/nixos-etc-metadata",
              "mount -t overlay overlay -o lowerdir=/run/nixos-etc-metadata,upperdir=/.rw-etc/upper,workdir=/.rw-etc/work,redirect_dir=on,metacopy=on /etc",
          )
          machine.fail("test -e /etc/hidden-file")

      with subtest("write to it"):
          machine.succeed(
              "echo local > /etc/local-file",
              "mkdir -p /etc/ssh && echo key > /etc/ssh/ssh_host_test_key",
              # A whiteout and a metacopy in the upper layer.
              "rm /etc/deleted-by-admin",
              "chmod 0600 /etc/chmodded",
              # Mounts on top of /etc.
              "mkdir /etc/mountpoint",
              "mount -t tmpfs tmpfs /etc/mountpoint",
              "touch /etc/mountpoint/extra-file",
              "touch /etc/filemount",
              "mount --bind /dev/null /etc/filemount",
          )
          machine.succeed("test -c /.rw-etc/upper/deleted-by-admin")
          machine_id = machine.succeed("cat /etc/machine-id")

      with subtest("switching migrates /etc to a configuration extension image"):
          machine.succeed("${confext}/bin/switch-to-configuration test")
          machine.succeed("grep -qxF .host /etc/.systemd-confext/confexts")
          machine.fail("mountpoint -q /run/nixos-etc-metadata")
          assert machine.succeed("cat /etc/managed") == "new"

      with subtest("the writes to the old /etc are kept"):
          assert machine.succeed("cat /etc/local-file") == "local\n"
          assert machine.succeed("cat /etc/ssh/ssh_host_test_key") == "key\n"
          assert machine.succeed("cat /etc/machine-id") == machine_id
          # The whiteout and the metacopy are dropped, so NixOS provides both
          # files again.
          assert machine.succeed("cat /etc/deleted-by-admin") == "provided by NixOS"
          assert machine.succeed("stat -c %a /etc/chmodded").strip() == "644"

      with subtest("mounts on top of /etc are carried over"):
          machine.succeed("findmnt /etc/mountpoint")
          machine.succeed("test -e /etc/mountpoint/extra-file")
          machine.succeed("findmnt /etc/filemount")
          machine.fail("test -e /run/nixos-etc-confext")

      with subtest("what was hidden below the overlay is set aside"):
          machine.fail("test -e /etc/hidden-file")
          assert machine.succeed("cat /.rw-etc/etc.pre-confext/hidden-file") == "hidden\n"
          machine.succeed("test -e /.rw-etc/migrated-to-confext")
          # Left alone for a rollback.
          machine.succeed("test -e /.rw-etc/upper/local-file")

      with subtest("writes land in the migrated /etc"):
          machine.succeed("echo more > /etc/more-file")
          machine.succeed("${confext}/bin/switch-to-configuration test")
          assert machine.succeed("cat /etc/more-file") == "more\n"
          machine.fail("systemctl list-units --failed --plain --no-legend | grep .")
    '';
}
