# Switching from the classic /etc that setup-etc.pl populates with symlinks to
# a configuration extension image, see system.etc.confext.
#
# The confext generations are nodes of their own, booted on the disk of the
# classic one, which is what rebooting into a new generation amounts to.
{ lib, ... }:
let
  classic =
    { ... }:
    {
      boot.initrd.systemd.enable = true;
      services.openssh.enable = true;
      users.users.alice = {
        isNormalUser = true;
        initialPassword = "initial";
      };
      environment.etc = {
        "managed".text = "old";
        # Copied rather than linked, and listed in /etc/.clean.
        "copied" = {
          text = "copied";
          mode = "0640";
        };
      };
    };

  confext =
    { lib, ... }:
    {
      system.etc.confext.enable = true;
      environment.etc."managed".text = lib.mkForce "new";
    };

  # The generation a classic node reboots into.
  rebootInto = name: {
    imports = [
      classic
      confext
    ];
    virtualisation.diskImage = "./${name}.qcow2";
  };
in
{
  name = "activation-etc-classic-migration";

  meta.maintainers = with lib.maintainers; [ jmbaur ];

  nodes = {
    # Switched to the confext generation live, then rebooted into it.
    machine = {
      imports = [ classic ];
      specialisation.confext.configuration = confext;
    };
    machineConfext = rebootInto "machine";

    # Rebooted into the confext generation without a live switch, which
    # migrates from the initrd.
    direct = classic;
    directConfext = rebootInto "direct";
  };

  testScript =
    { nodes, ... }:
    let
      switchTo = "${nodes.machine.system.build.toplevel}/specialisation/confext/bin/switch-to-configuration";
      vm = name: "${nodes.${name}.system.build.vm}/bin/run-${nodes.${name}.system.name}-vm";
    in
    # python
    ''
      def boot_on_disk_of(name, vm):
          m = create_machine(start_command=vm, name=name, keep_machine_state=True)
          m.start()
          m.wait_for_unit("multi-user.target")
          return m

      def classic_etc(m):
          m.fail("findmnt --mountpoint /etc")
          m.succeed("test -L /etc/static")
          assert m.succeed("readlink /etc/nsswitch.conf") == "/etc/static/nsswitch.conf\n"

      def confext_etc(m):
          m.succeed("findmnt --mountpoint /etc --types overlay")
          m.succeed("grep -qxF .host /etc/.systemd-confext/confexts")
          assert m.succeed("readlink /etc/nsswitch.conf").startswith("/nix/store")
          assert m.succeed("readlink /etc/static").startswith("/nix/store")

      def write_state(m):
          m.wait_for_unit("sshd.service")
          classic_etc(m)
          m.succeed("grep -qx copied /etc/.clean")
          m.succeed(
              "echo local > /etc/local-file",
              "mkdir -p /etc/nixos && echo '{ }' > /etc/nixos/configuration.nix",
              "echo 'alice:changed' | chpasswd",
          )
          return {
              "machine-id": m.succeed("cat /etc/machine-id"),
              "host key": m.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub"),
              "alice": m.succeed("getent shadow alice"),
          }

      def migrated(m, state):
          confext_etc(m)
          assert m.succeed("cat /etc/managed") == "new"
          # The copy setup-etc.pl made is gone, the one in the image is there.
          assert m.succeed("stat -c %a /etc/copied").strip() == "640"
          m.fail("test -e /etc/.clean")
          assert m.succeed("cat /etc/local-file") == "local\n"
          assert m.succeed("cat /etc/nixos/configuration.nix") == "{ }\n"
          assert m.succeed("cat /etc/machine-id") == state["machine-id"]
          assert m.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub") == state["host key"]
          assert m.succeed("getent shadow alice") == state["alice"]
          m.succeed("systemctl is-active sshd.service")
          m.fail("systemctl list-units --failed --plain --no-legend | grep .")

      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("state written to the classic /etc"):
          state = write_state(machine)

      with subtest("switching migrates the running system"):
          machine.succeed("${switchTo} test")
          migrated(machine, state)
          machine.succeed("echo more > /etc/more-file")

      with subtest("the confext generation boots with the migrated /etc"):
          machine.shutdown()
          rebooted = boot_on_disk_of("machine", "${vm "machineConfext"}")
          migrated(rebooted, state)
          assert rebooted.succeed("cat /etc/more-file") == "more\n"
          log = rebooted.succeed("journalctl -b -u systemd-confext.service --no-pager")
          assert "/etc is up to date" in log, log
          rebooted.shutdown()

      with subtest("rolling back brings the symlink farm back"):
          machine.start()
          machine.wait_for_unit("multi-user.target")
          classic_etc(machine)
          assert machine.succeed("cat /etc/managed") == "old"
          assert machine.succeed("cat /etc/local-file") == "local\n"
          assert machine.succeed("cat /etc/more-file") == "more\n"
          assert machine.succeed("getent shadow alice") == state["alice"]

      with subtest("switching forward again migrates again"):
          machine.succeed("${switchTo} test")
          migrated(machine, state)
          machine.shutdown()

      with subtest("rebooting into the confext generation migrates from the initrd"):
          direct.start()
          direct.wait_for_unit("multi-user.target")
          direct_state = write_state(direct)
          direct.shutdown()
          rebooted = boot_on_disk_of("direct", "${vm "directConfext"}")
          migrated(rebooted, direct_state)
          rebooted.shutdown()
    '';
}
