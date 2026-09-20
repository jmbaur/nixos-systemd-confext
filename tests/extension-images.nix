{ lib, ... }:
let
  # Where the test installs the images a unit extends its /etc with. Images
  # meant for a single unit deliberately do not live in /var/lib/confexts:
  # systemd-confext would merge those into the system's /etc instead.
  imageDirectory = "/var/lib/unit-confexts";
in
{
  name = "systemd-confext-extension-images";

  meta.maintainers = with lib.maintainers; [ jmbaur ];

  nodes =
    let
      common =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          file = name: text: pkgs.writeText name text;

          # Copies what a unit sees below /etc out to /run, which is shared
          # with the host, so that the test can read it back from outside the
          # unit's mount namespace. The directory is swapped into place once
          # it is complete, so the test never reads a half-written probe.
          probe = pkgs.writeShellScript "confext-probe" ''
            out="/run/confext-probe/$1"
            shift
            rm -rf "$out" "$out.tmp"
            mkdir -p "$out.tmp"
            for name in "$@"; do
              if [ -e "/etc/$name" ]; then
                cat "/etc/$name" > "$out.tmp/$name"
              fi
            done
            mv -T "$out.tmp" "$out"
          '';

          paths = "confext-app confext-dir confext-shared confext-host";

          # Appends what the running service sees as /etc/confext-app to a log
          # on /run, once at every start and reload.
          report = pkgs.writeShellScript "confext-report" ''
            mkdir -p /run/confext-probe
            {
              if [ -e /etc/confext-app ]; then
                cat /etc/confext-app
              else
                printf missing
              fi
              printf '\n'
            } >> /run/confext-probe/reload.log
          '';

          probeUnit =
            {
              name,
              serviceConfig,
              wantedBy ? [ "multi-user.target" ],
            }:
            {
              inherit wantedBy;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${probe} ${name} ${paths}";
              }
              // serviceConfig;
            };

          # An image is state, not part of the system closure: the unit names
          # the path it will be installed at, and starts without it.
          image = name: "-${imageDirectory}/${name}";
        in
        {
          environment.etc = {
            "confext-host".text = "host";
            # Both the host and the images carry this one.
            "confext-shared".text = "host";
          };

          # Only in the VM's store, for the test to install at runtime.
          system.extraDependencies = lib.attrValues config.system.build.confexts;

          system.build.confexts = {
            app1 = pkgs.makeConfext {
              name = "app";
              files = {
                "confext-app" = file "confext-app" "app 1";
                "confext-shared" = file "confext-shared" "app";
              };
            };

            # A newer version of the same image, for the .v/ directory.
            app2 = pkgs.makeConfext {
              name = "app";
              files = {
                "confext-app" = file "confext-app" "app 2";
                "confext-shared" = file "confext-shared" "app";
              };
            };

            top = pkgs.makeConfext {
              name = "top";
              files."confext-shared" = file "confext-shared" "top";
            };

            dir = pkgs.makeConfext {
              name = "dir";
              format = "directory";
              files."confext-dir" = file "confext-dir" "dir";
            };

            # Pinned to a release the host does not run, so systemd refuses it
            # and the unit fails to start.
            mismatch = pkgs.makeConfext {
              name = "mismatch";
              extensionRelease = {
                ID = config.system.nixos.distroId;
                VERSION_ID = "0.0";
              };
              files."confext-app" = file "confext-app" "should not be merged";
            };
          };

          systemd.services = {
            # A versioned directory: systemd resolves app.raw.v to the newest
            # app_VERSION.raw inside it, see systemd.v(7).
            confext-image = probeUnit {
              name = "image";
              serviceConfig.ExtensionImages = [ (image "app.raw.v") ];
            };

            # Two images at once: the one listed last is the top layer.
            confext-layered = probeUnit {
              name = "layered";
              serviceConfig.ExtensionImages = [
                (image "app.raw.v")
                (image "top.raw")
              ];
            };

            # A directory image, which carries the same extension-release
            # metadata but is mounted without a loop device.
            confext-directory = probeUnit {
              name = "directory";
              serviceConfig.ExtensionDirectories = [ (image "dir.v") ];
            };

            # An image named in the store, which systemd only accepts with the
            # extension-release name check turned off: it insists that the
            # image file is named after the extension-release file inside it,
            # and a store path never is.
            confext-store = probeUnit {
              name = "store";
              serviceConfig.ExtensionImages = [
                "${config.system.build.confexts.app1}:x-systemd.relax-extension-release-check"
              ];
            };

            # The same image without the option, to show that the name check
            # is what a store path falls foul of. Started by the test.
            confext-store-strict = probeUnit {
              name = "store-strict";
              wantedBy = [ ];
              serviceConfig.ExtensionImages = [ "${config.system.build.confexts.app1}" ];
            };

            # Started by the test, and expected to fail.
            confext-mismatch = probeUnit {
              name = "mismatch";
              wantedBy = [ ];
              serviceConfig.ExtensionImages = [ (image "mismatch.raw") ];
            };

            # A long-running service, to reload rather than restart when the
            # image changes. RefreshOnReload= defaults to "extensions", which
            # re-merges the extensions in the namespace of the running
            # process - but only for extensions named by a .v/ directory.
            confext-reload = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExtensionImages = [ (image "app.raw.v") ];
                # Bounds the refresh helper, which hangs where the refresh is
                # not supported.
                TimeoutStartSec = "10s";
                ExecStart = pkgs.writeShellScript "confext-reload-start" ''
                  ${report}
                  exec sleep infinity
                '';
                ExecReload = report;
              };
            };
          };
        };
    in
    {
      # A stock NixOS /etc: attaching an extension to a unit needs nothing
      # from this module, only an image pkgs.makeConfext can build.
      plain = common;

      # /etc built from an image, so that a unit's extension is an overlay
      # stacked on top of the overlay the system's /etc already is.
      confext = {
        imports = [ common ];
        system.etc.confext.enable = true;
        boot.initrd.systemd.enable = true;
      };
    };

  testScript =
    { nodes, ... }:
    let
      confexts = nodes.plain.system.build.confexts;
    in
    ''
      def probe(machine, unit, name):
          return machine.succeed(f"cat /run/confext-probe/{unit}/{name}")

      def missing(machine, unit, name):
          machine.fail(f"test -e /run/confext-probe/{unit}/{name}")

      def install(machine):
          """Installs the images the units expect, as a deployment would."""
          machine.succeed(
              "mkdir -p ${imageDirectory}/app.raw.v ${imageDirectory}/dir.v",
              "cp ${confexts.app1} ${imageDirectory}/app.raw.v/app_1.raw",
              "cp ${confexts.top} ${imageDirectory}/top.raw",
              "cp -r ${confexts.dir} ${imageDirectory}/dir.v/dir_1",
              "cp ${confexts.mismatch} ${imageDirectory}/mismatch.raw",
          )

      for machine in [plain, confext]:
          machine.wait_for_unit("multi-user.target")

          with subtest(f"{machine.name}: a unit starts without its images installed"):
              # The paths are prefixed with "-", so a unit whose extensions are
              # not deployed (yet) sees nothing but the host's /etc.
              machine.succeed("systemctl is-active confext-image.service")
              missing(machine, "image", "confext-app")
              assert probe(machine, "image", "confext-host") == "host"

          install(machine)

          with subtest(f"{machine.name}: an image is merged into the unit's /etc only"):
              machine.succeed("systemctl restart confext-image.service")
              assert probe(machine, "image", "confext-app") == "app 1"
              # The overlay lives in the unit's mount namespace, so the host's
              # own /etc never sees the image.
              machine.fail("test -e /etc/confext-app")

          with subtest(f"{machine.name}: the host's /etc shows through below the image"):
              assert probe(machine, "image", "confext-host") == "host"
              # Unlike the system-wide merge, where the underlying /etc is the
              # writable upper layer, a unit's extensions sit above /etc.
              assert probe(machine, "image", "confext-shared") == "app"
              assert machine.succeed("cat /etc/confext-shared") == "host"

          with subtest(f"{machine.name}: a .v/ directory resolves to the newest image"):
              machine.succeed("cp ${confexts.app2} ${imageDirectory}/app.raw.v/app_2.raw")
              machine.succeed("systemctl restart confext-image.service")
              assert probe(machine, "image", "confext-app") == "app 2"
              resolved = machine.succeed("systemd-vpick --suffix=.raw ${imageDirectory}/app.raw.v")
              assert resolved.strip().endswith("app_2.raw"), resolved

          with subtest(f"{machine.name}: images are layered in the order they are listed"):
              machine.succeed("systemctl restart confext-layered.service")
              assert probe(machine, "layered", "confext-app") == "app 2"
              assert probe(machine, "layered", "confext-shared") == "top"

          with subtest(f"{machine.name}: a directory image works through ExtensionDirectories="):
              machine.succeed("systemctl restart confext-directory.service")
              assert probe(machine, "directory", "confext-dir") == "dir"
              assert probe(machine, "directory", "confext-host") == "host"
              machine.fail("test -e /etc/confext-dir")

          with subtest(f"{machine.name}: an image in the store needs the name check off"):
              machine.succeed("systemctl is-active confext-store.service")
              assert probe(machine, "store", "confext-app") == "app 1"
              machine.fail("systemctl start confext-store-strict.service")
              machine.fail("test -e /run/confext-probe/store-strict")

          with subtest(f"{machine.name}: an image for another release is refused"):
              machine.fail("systemctl start confext-mismatch.service")
              machine.fail("test -e /run/confext-probe/mismatch")

          machine.succeed("rm ${imageDirectory}/app.raw.v/app_2.raw")

      with subtest("plain: reloading a service refreshes its extensions"):
          plain.succeed("systemctl reload confext-reload.service")
          reloads = plain.succeed("cat /run/confext-probe/reload.log").splitlines()
          # Started before any image was installed and reloaded after, all
          # without the service being restarted.
          assert reloads == ["missing", "app 1"], reloads

      with subtest("confext: a reload cannot refresh extensions over an overlay /etc"):
          # To rebuild a unit's /etc overlay in place, systemd unmounts it and
          # expects to find a plain directory below. An /etc that is an image
          # itself is an overlay, so it refuses - as it does on a system with
          # the composefs /etc nixpkgs used to have. Starting and restarting the unit
          # is unaffected, only RefreshOnReload=extensions is.
          confext.fail("systemctl reload confext-reload.service")
          confext.succeed("journalctl -b --no-pager | grep -q \"'(sd-ns-unpeel)' failed\"")
          confext.succeed("systemctl is-active confext-reload.service")
          reloads = confext.succeed("cat /run/confext-probe/reload.log").splitlines()
          assert reloads == ["missing"], reloads
          confext.succeed("systemctl restart confext-reload.service")
          # Type=simple, so the restart returns before the service has run.
          confext.wait_until_succeeds("test $(wc -l < /run/confext-probe/reload.log) = 2")
          reloads = confext.succeed("cat /run/confext-probe/reload.log").splitlines()
          assert reloads == ["missing", "app 1"], reloads

      with subtest("the system's own /etc image is below the unit's extensions"):
          # What the unit sees of the host comes from the system's own image,
          # and the unit's extension overlays it.
          confext.succeed("findmnt --mountpoint /etc --types overlay")
          assert confext.succeed("cat /etc/confext-shared") == "host"
          assert probe(confext, "image", "confext-shared") == "app"
    '';
}
