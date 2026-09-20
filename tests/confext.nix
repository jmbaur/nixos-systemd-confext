{ lib, ... }:
let
  # What systemd-stub unpacks from the EFI system partition, which it puts in
  # /.extra in the initrd: per-UKI images from <uki>.efi.extra.d/ and global
  # ones from /loader/extensions/. The test bakes them into the initrd at the
  # paths the stub would, since the VM boots without a UKI. systemd only merges
  # them into the initrd's own /etc, and nothing hands them over to the system.
  #
  # Like the stub, this adds them as a cpio archive of its own: systemd only
  # holds images to its stricter policy for /.extra if they are really there,
  # and not symlinks into the store as boot.initrd.systemd.contents makes.
  espNode =
    imagePolicy:
    { pkgs, ... }:
    let
      image =
        name: text:
        pkgs.makeConfext {
          inherit name;
          extensionRelease = {
            ID = "_any";
            CONFEXT_SCOPE = "initrd";
          };
          files."${name}-file" = pkgs.writeText "${name}-file" text;
        };
    in
    {
      boot.initrd.systemd.enable = true;
      systemd.confext.initrd = {
        enable = true;
        inherit imagePolicy;
      };

      boot.initrd.prepend = [
        "${pkgs.runCommand "esp-confexts.cpio" { nativeBuildInputs = [ pkgs.cpio ]; } ''
          mkdir -p root/.extra/confext root/.extra/global_confext
          cp ${image "esp" "from the EFI system partition"} root/.extra/confext/esp.confext.raw
          cp ${image "global" "from /loader/extensions"} root/.extra/global_confext/global.confext.raw
          cd root
          find . -print0 | sort -z | cpio -o -H newc -R +0:+0 --reproducible --null > $out
        ''}"
      ];

      # Reports what the initrd's /etc looks like to the booted system, which
      # shares /run with the initrd. Merging fails when an image is refused,
      # so this does not require it to succeed.
      boot.initrd.systemd.services.initrd-confext-probe = {
        requiredBy = [ "initrd-fs.target" ];
        before = [ "initrd-fs.target" ];
        wants = [ "systemd-confext-initrd.service" ];
        after = [ "systemd-confext-initrd.service" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p /run/initrd-probe
          cp /etc/esp-file /etc/global-file /run/initrd-probe/ || true
        '';
      };
    };
in
{
  name = "systemd-confext";

  meta.maintainers = with lib.maintainers; [ jmbaur ];

  nodes.machine =
    { config, pkgs, ... }:
    let
      file = name: text: pkgs.writeText name text;
    in
    {
      boot.initrd.systemd.enable = true;
      system.etc.confext.enable = true;

      # Images are deliberately not part of the system closure. The test
      # installs them into /var/lib/confexts at runtime, which is how confexts
      # are meant to be applied. `system.extraDependencies` only makes them
      # available in the VM's store, like a registry or a USB stick would.
      system.build.confexts = {
        greeting = pkgs.makeConfext {
          format = "directory";
          name = "greeting";
          files = {
            "greeting" = file "greeting" "hello from a directory confext";
            # Sorts above .host, so it wins over the NixOS-managed file.
            "shadowed" = file "shadowed" "confext";
          };
        };

        raw = pkgs.makeConfext {
          name = "raw";
          format = "erofs";
          files."confext-raw/value" = file "value" "erofs";
        };

        squash = pkgs.makeConfext {
          name = "squash";
          format = "squashfs";
          files."confext-squash" = file "confext-squash" "squashfs";
        };

        # Pinned to a release the host doesn't run, so systemd refuses it.
        mismatch = pkgs.makeConfext {
          name = "mismatch";
          format = "erofs";
          extensionRelease = {
            ID = config.system.nixos.distroId;
            VERSION_ID = "0.0";
          };
          files."confext-mismatch" = file "confext-mismatch" "should not be merged";
        };
      };

      system.extraDependencies = lib.attrValues config.system.build.confexts;

      environment.etc."host-file".text = "host";
      environment.etc."shadowed".text = "nixos";

      specialisation.changed.configuration = {
        environment.etc."host-file".text = lib.mkForce "host changed";
      };
    };

  # The initrd's own /etc, extended by an image the initrd carries. This is
  # the initrd's configuration, not the system's: the image is gone from /etc
  # once the initrd hands over to the system.
  nodes.initrd =
    { config, pkgs, ... }:
    {
      boot.initrd.systemd.enable = true;
      systemd.confext.initrd.enable = true;

      boot.initrd.systemd.contents."/usr/local/lib/confexts/initrd-confext.raw".source =
        pkgs.makeConfext
          {
            name = "initrd-confext";
            extensionRelease = {
              ID = "_any";
              # Extensions are for the system unless they say otherwise, and
              # systemd skips the ones that are not meant for the initrd.
              CONFEXT_SCOPE = "initrd";
            };
            files."initrd-confext" = pkgs.writeText "initrd-confext" "merged in the initrd";
          };

      # The same image without the scope, which the initrd has to ignore.
      boot.initrd.systemd.contents."/usr/local/lib/confexts/system-confext.raw".source =
        pkgs.makeConfext
          {
            name = "system-confext";
            files."system-confext" = pkgs.writeText "system-confext" "for the system";
          };

      # Reports what the initrd's /etc looks like to the booted system, which
      # shares /run with the initrd.
      boot.initrd.systemd.services.initrd-confext-probe = {
        requiredBy = [ "initrd-fs.target" ];
        before = [ "initrd-fs.target" ];
        requires = [ "systemd-confext-initrd.service" ];
        after = [ "systemd-confext-initrd.service" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p /run/initrd-probe
          cp /etc/initrd-confext /run/initrd-probe/ || true
          cp /etc/system-confext /run/initrd-probe/ || true
          # The initrd writes to its own /etc while booting, so the merged
          # /etc has to stay writable.
          echo written > /etc/initrd-confext-write
          cp /etc/initrd-confext-write /run/initrd-probe/
        '';
      };
    };

  # Unsigned images from the EFI system partition, which systemd refuses by
  # default since the partition is not trusted.
  nodes.esp = espNode null;

  # The same images with a policy that accepts unsigned ones.
  nodes.esp_policy = espNode "root=verity+signed+encrypted+unprotected+absent:=ignore";

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.machine.system.build) confexts;
      changed = "${nodes.machine.system.build.toplevel}/specialisation/changed";
    in
    ''
      machine.wait_for_unit("multi-user.target")

      def reload():
          # What picks up images installed at runtime, with the options NixOS
          # passes to systemd-confext.
          machine.succeed("systemctl reload systemd-confext.service")

      def merged():
          return machine.succeed("cat /etc/.systemd-confext/confexts")

      with subtest("only the system's own image is merged at boot"):
          machine.succeed("findmnt --mountpoint /etc --types overlay")
          assert merged().split() == [".host"], merged()
          machine.succeed("test -d /var/lib/confexts")
          machine.fail("test -e /etc/greeting")

      with subtest("an image carries no store paths"):
          # It is installed on machines that were not built from this store.
          machine.fail("grep -qaF ${builtins.storeDir}/ ${confexts.raw}")
          machine.fail("grep -rqaF ${builtins.storeDir}/ ${confexts.greeting}")
          machine.fail("find ${confexts.greeting} -type l -lname '${builtins.storeDir}/*' | grep -q .")

      with subtest("reloading merges an installed directory image"):
          machine.succeed("cp -r ${confexts.greeting} /var/lib/confexts/greeting")
          reload()
          assert machine.succeed("cat /etc/greeting") == "hello from a directory confext"
          assert machine.succeed("cat /etc/host-file") == "host"
          # Above the system's own image, so it overrides what NixOS manages.
          assert machine.succeed("cat /etc/shadowed") == "confext"

      with subtest("reloading picks up newly installed disk images"):
          machine.succeed("cp ${confexts.raw} /var/lib/confexts/raw.raw")
          machine.succeed("cp ${confexts.squash} /var/lib/confexts/squash.raw")
          reload()
          assert machine.succeed("cat /etc/confext-raw/value") == "erofs"
          assert machine.succeed("cat /etc/confext-squash") == "squashfs"
          assert machine.succeed("cat /etc/greeting") == "hello from a directory confext"

      with subtest("systemd-confext status and list report the merge"):
          status = machine.succeed("systemd-confext status --no-pager")
          assert "/etc" in status, status
          images = machine.succeed("systemd-confext list --no-legend --no-pager")
          for name in ["greeting", "raw", "squash", ".host"]:
              assert name in images, images

      with subtest("an image for another release is not merged"):
          machine.succeed("cp ${confexts.mismatch} /var/lib/confexts/mismatch.raw")
          reload()
          machine.fail("test -e /etc/confext-mismatch")
          assert "mismatch" not in merged(), merged()
          assert machine.succeed("cat /etc/greeting") == "hello from a directory confext"
          machine.succeed("rm /var/lib/confexts/mismatch.raw")

      with subtest("writes to the merged /etc reach the underlying /etc"):
          machine.succeed("echo written > /etc/written")

      with subtest("switching generations keeps extensions merged"):
          machine.succeed("${changed}/bin/switch-to-configuration test")
          assert machine.succeed("cat /etc/host-file") == "host changed"
          assert machine.succeed("cat /etc/greeting") == "hello from a directory confext"

      with subtest("installed images are merged again after reboot"):
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("systemctl is-active systemd-confext.service")
          assert machine.succeed("cat /etc/greeting") == "hello from a directory confext"
          assert machine.succeed("cat /etc/confext-squash") == "squashfs"
          assert machine.succeed("cat /etc/written") == "written\n"
          # The generation that was booted, not the one switched to.
          assert machine.succeed("cat /etc/host-file") == "host"

      with subtest("removing an image and reloading drops it"):
          machine.succeed("rm -rf /var/lib/confexts/greeting")
          reload()
          machine.fail("test -e /etc/greeting")
          assert machine.succeed("cat /etc/shadowed") == "nixos"
          assert machine.succeed("cat /etc/confext-squash") == "squashfs"

      with subtest("an image carried by the initrd extends the initrd's /etc"):
          initrd.wait_for_unit("multi-user.target")
          assert initrd.succeed("cat /run/initrd-probe/initrd-confext") == "merged in the initrd"
          assert initrd.succeed("cat /run/initrd-probe/initrd-confext-write") == "written\n"
          # An image without CONFEXT_SCOPE=initrd is not for the initrd.
          initrd.fail("test -e /run/initrd-probe/system-confext")
          # The system's /etc is untouched by it.
          initrd.fail("test -e /etc/initrd-confext")
          initrd.fail("findmnt --mountpoint /etc --types overlay")

      with subtest("unsigned images from the EFI system partition are refused"):
          esp.wait_for_unit("multi-user.target")
          esp.succeed("test -d /run/initrd-probe")
          # systemd gives up at the first image it refuses, whichever that is.
          esp.succeed(
              "journalctl -b --no-pager | grep -E '/\\.extra/(global_)?confext/[^:]+: Image does not match image policy'"
          )
          esp.fail("test -e /run/initrd-probe/esp-file")
          esp.fail("test -e /run/initrd-probe/global-file")
          esp.fail("test -e /etc/esp-file")

      with subtest("images from the EFI system partition only extend the initrd's /etc"):
          esp_policy.wait_for_unit("multi-user.target")
          assert esp_policy.succeed("cat /run/initrd-probe/esp-file") == "from the EFI system partition"
          assert esp_policy.succeed("cat /run/initrd-probe/global-file") == "from /loader/extensions"
          # Gone with the initrd: nothing hands them over to the system.
          esp_policy.fail("test -e /etc/esp-file")
          esp_policy.fail("test -e /etc/global-file")
          esp_policy.fail("test -e /run/confexts/esp.confext.raw")
          esp_policy.fail("findmnt --mountpoint /etc --types overlay")
    '';
}
