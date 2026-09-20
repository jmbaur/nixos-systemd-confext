# The module: `systemd.confext` runs systemd-confext against /etc, and
# `system.etc.confext` builds /etc itself as the image below the ones
# installed at runtime. They are two halves of one arrangement - an image
# dropped into /var/lib/confexts is merged over the /etc the other half
# builds - so both option trees always come together.
{
  imports = [
    ./confext.nix
    ./etc.nix
  ];
}
