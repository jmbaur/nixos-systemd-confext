{ lib, ... }:
{
  name = "activation-etc-confext";

  meta.maintainers = with lib.maintainers; [ jmbaur ];

  nodes = {
    machine =
      { config, pkgs, ... }:
      {
        system.etc.confext.enable = true;
        boot.initrd.systemd.enable = true;

        # sudo refuses to run unless /etc/sudoers is exactly 0440 root:root,
        # which the image has to carry for it.
        security.sudo.enable = true;

        # For the nixos-enter subtest; the test framework disables Nix.
        system.tools.nixos-enter.enable = true;

        environment.etc = {
          "confext-file".text = "base";
          "confext-gone".text = "gone in the next generation";
          "confext-deleted".text = "deleted by the admin";
          "confext-mode" = {
            text = "restricted";
            mode = "0440";
          };
          "confext-owned" = {
            text = "owned";
            mode = "0600";
            uid = 1234;
            gid = 5678;
          };
        };

        # Installed at runtime, and named so that it sorts above the system's
        # own image and hence wins over it.
        system.build.override = pkgs.makeConfext {
          name = "zz-override";
          files."confext-file" = pkgs.writeText "confext-file" "override";
        };
        system.extraDependencies = [ config.system.build.override ];

        # The host's own transfers, which are in its image.
        systemd.sysupdate = {
          enable = true;
          transfers.example = {
            Transfer.Verify = false;
            Source = {
              Type = "regular-file";
              Path = "/var/lib/example-source";
              MatchPattern = "example_@v";
            };
            Target = {
              Type = "regular-file";
              Path = "/var/lib/example";
              MatchPattern = "example_@v";
            };
          };
        };
        systemd.tmpfiles.settings.example = {
          "/var/lib/example-source".d.mode = "0755";
          "/var/lib/example".d.mode = "0755";
        };

        specialisation.next.configuration = {
          environment.etc."confext-file".text = lib.mkForce "next";
          environment.etc."confext-new".text = "new";
          systemd.services.confext-unit = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            script = "true";
          };
          environment.etc."confext-gone".enable = false;
        };
      };

    # A system that used to mount /etc from the composefs image of the old
    # system.etc.overlay, whose writes live in /.rw-etc/upper.
    overlay =
      { pkgs, ... }:
      {
        system.etc.confext.enable = true;
        boot.initrd.systemd.enable = true;
        environment.etc."confext-file".text = "base";
        environment.systemPackages = [ pkgs.attr ];
      };
  };

  testScript =
    { nodes, ... }:
    let
      base = nodes.machine.system.build.toplevel;
      next = "${base}/specialisation/next";
      override = nodes.machine.system.build.override;
    in
    ''
      machine.wait_for_unit("multi-user.target")

      with subtest("/etc is merged from the system's own image"):
          machine.succeed("findmnt --mountpoint /etc --types overlay")
          merged = machine.succeed("cat /etc/.systemd-confext/confexts")
          assert ".host" in merged, merged
          assert machine.succeed("cat /etc/confext-file") == "base"
          # The symlinks come straight from the image, not from /etc/static.
          assert machine.succeed("readlink /etc/nsswitch.conf").startswith("/nix/store")
          machine.succeed("test -e /etc/static/os-release")
          # The pointer at this generation's image is runtime state, written
          # again on every boot. /var/lib/confexts is left to the admin.
          assert machine.succeed("readlink /run/confexts/.host.raw").startswith("/nix/store")
          machine.fail("test -e /var/lib/confexts/.host.raw")

      with subtest("the image carries file modes and ownership"):
          assert machine.succeed("stat -c %a /etc/confext-mode").strip() == "440"
          assert machine.succeed("stat -c %u:%g:%a /etc/confext-owned").strip() == "1234:5678:600"
          # sudo checks the mode of /etc/sudoers itself and refuses 0444.
          machine.succeed("sudo -n true")

      with subtest("/etc is writable and writes land in the underlying /etc"):
          machine.succeed("echo local > /etc/local-file")
          machine.succeed("test -e /etc/machine-id")

      with subtest("switching migrates /etc to the new generation"):
          # A file deleted from the merged /etc leaves a whiteout behind, which
          # the switch clears for the paths the image provides.
          machine.succeed("rm /etc/confext-deleted")
          # Anything else in the upper layer is the admin's.
          machine.succeed("mkdir /etc/local-dir && touch /etc/local-dir/file && rm /etc/local-dir/file")
          machine.succeed("${next}/bin/switch-to-configuration test")
          assert machine.succeed("cat /etc/confext-deleted") == "deleted by the admin"
          machine.fail("test -e /etc/local-dir/file")
          assert machine.succeed("cat /etc/confext-file") == "next"
          assert machine.succeed("cat /etc/confext-new") == "new"
          machine.fail("test -e /etc/confext-gone")
          # A unit that only the new generation ships starts from the image.
          machine.succeed("systemctl is-active confext-unit.service")
          assert machine.succeed("cat /etc/local-file") == "local\n"

      with subtest("switching back restores the previous /etc"):
          machine.succeed("${base}/bin/switch-to-configuration test")
          assert machine.succeed("cat /etc/confext-file") == "base"
          machine.fail("test -e /etc/confext-new")
          assert machine.succeed("cat /etc/confext-gone") == "gone in the next generation"

      with subtest("systemd-sysupdated takes the image for the host's own"):
          machine.succeed("test -f /etc/sysupdate.d/example.transfer")
          targets = machine.succeed("updatectl list")
          print(targets)
          assert "host" in targets, targets
          assert "confext" not in targets, targets
          machine.succeed("echo 1 > /var/lib/example-source/example_1")
          machine.succeed("updatectl update")
          machine.succeed("test -f /var/lib/example/example_1")

      with subtest("an image installed at runtime overrides the system's /etc"):
          machine.succeed("cp ${override} /var/lib/confexts/zz-override.raw")
          machine.succeed("systemctl reload systemd-confext.service")
          assert machine.succeed("cat /etc/confext-file") == "override"
          # The rest of /etc is still there.
          assert machine.succeed("cat /etc/confext-gone") == "gone in the next generation"
          machine.succeed("systemctl daemon-reload")

      with subtest("removing it hands /etc back to the system's image"):
          machine.succeed("rm /var/lib/confexts/zz-override.raw")
          machine.succeed("systemctl reload systemd-confext.service")
          assert machine.succeed("cat /etc/confext-file") == "base"

      with subtest("/etc is merged again after a reboot"):
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("findmnt --mountpoint /etc --types overlay")
          assert machine.succeed("cat /etc/confext-file") == "base"
          assert machine.succeed("cat /etc/local-file") == "local\n"
          # /run is empty at boot, so the initrd wrote the pointer again.
          assert machine.succeed("readlink /run/confexts/.host.raw").startswith("/nix/store")
          # The initrd already merged it, so the service leaves it alone.
          confext_log = machine.succeed("journalctl -b -u systemd-confext.service --no-pager")
          assert "/etc is up to date" in confext_log, confext_log

      with subtest("nixos-enter merges /etc in the chroot"):
          # The root filesystem mounted a second time is what a rescue system
          # sees: the underlying /etc, with nothing merged over it.
          machine.succeed(
              "mkdir -p /mnt",
              "mount $(findmnt --noheadings --output SOURCE --mountpoint /) /mnt",
              "mkdir -p /mnt/nix/store",
              "mount --bind /nix/store /mnt/nix/store",
          )
          machine.fail("test -e /mnt/etc/confext-file")
          machine.succeed("test -e /mnt/etc/NIXOS")

          # A resolv.conf of the host's own, to tell it apart from the chroot's.
          machine.succeed("echo 'nameserver 192.0.2.1' > /tmp/resolv.conf")
          def enter(command):
              return machine.succeed(
                  "unshare --mount sh -c 'mount --bind /tmp/resolv.conf /etc/resolv.conf && "
                  f"nixos-enter --root /mnt --system ${base} -c \"{command}\"'"
              )

          assert enter("cat /etc/confext-file") == "base"
          assert enter("cat /etc/local-file") == "local\n"
          assert enter("readlink /etc/nsswitch.conf").startswith("/nix/store")
          assert enter("stat -c %a /etc/confext-mode").strip() == "440"
          assert enter("cat /etc/resolv.conf") == "nameserver 192.0.2.1\n"
          assert enter("getent passwd root").startswith("root:")

          # Everything was mounted in nixos-enter's own namespace, and none of
          # it is left behind on the disk.
          machine.fail("findmnt --mountpoint /mnt/etc")
          machine.fail("test -e /mnt/etc/.systemd-confext")
          assert machine.succeed("cat /etc/resolv.conf") != "nameserver 192.0.2.1\n"
          assert machine.succeed("cat /etc/confext-file") == "base"
          machine.succeed("umount /mnt/nix/store /mnt")

      with subtest("the upper layer of the old /etc overlay is migrated on boot"):
          overlay.wait_for_unit("multi-user.target")
          # What system.etc.overlay leaves behind: writes in its upper layer,
          # including a whiteout and a metacopy file of NixOS-managed ones,
          # and an underlying /etc that was hidden below the overlay.
          overlay.succeed(
              "mkdir -p /.rw-etc/upper/ssh /.rw-etc/work",
              "echo kept > /.rw-etc/upper/kept-file",
              "echo key > /.rw-etc/upper/ssh/ssh_host_test_key",
              "chmod 0600 /.rw-etc/upper/ssh/ssh_host_test_key",
              "mknod /.rw-etc/upper/confext-file c 0 0",
              "touch /.rw-etc/upper/metacopy-file",
              "setfattr -n trusted.overlay.metacopy /.rw-etc/upper/metacopy-file",
              "echo hidden > /etc/hidden-file",
          )
          overlay.shutdown()
          overlay.start()
          overlay.wait_for_unit("multi-user.target")
          overlay.succeed("findmnt --mountpoint /etc --types overlay")
          assert overlay.succeed("cat /etc/kept-file") == "kept\n"
          assert overlay.succeed("stat -c %a /etc/ssh/ssh_host_test_key").strip() == "600"
          assert overlay.succeed("cat /etc/confext-file") == "base"
          overlay.fail("test -e /etc/metacopy-file")
          overlay.fail("test -e /etc/hidden-file")
          assert overlay.succeed("cat /.rw-etc/etc.pre-confext/hidden-file") == "hidden\n"
          overlay.succeed("test -e /.rw-etc/migrated-to-confext")
          # It only happens once.
          overlay.succeed("echo again > /.rw-etc/upper/again")
          overlay.shutdown()
          overlay.start()
          overlay.wait_for_unit("multi-user.target")
          overlay.fail("test -e /etc/again")
          assert overlay.succeed("cat /etc/kept-file") == "kept\n"
    '';
}
