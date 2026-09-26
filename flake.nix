{
  description = "Custom NixOS Installer ISO with Bcachefs Support";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Single source of truth for install.sh stays in the main repo;
    # this input bakes that file into the ISO at build time.
    # `flake = false` => plain source snapshot, no transitive locking.
    # After changing install.sh upstream, run:
    #   nix flake update nixos-repo
    # ...before rebuilding the ISO, or the ISO ships the old script.
    nixos-repo = {
      url = "github:waxkb/nixos";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-repo,
    }:
    {
      nixosConfigurations.iso = nixpkgs.lib.nixosSystem {
        # Change "x86_64-linux" to "aarch64-linux" if your Chromebook uses an ARM processor
        system = "x86_64-linux";

        modules = [
          # Pulls in the official minimal installation CD configuration profile
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"

          (
            {
              pkgs,
              ...
            }:
            {
              # Force the live kernel to build and include the out-of-tree bcachefs module
              boot.supportedFilesystems = [ "bcachefs" ];

              environment.etc."nixos-installer/install.sh".source = "${nixos-repo}/install.sh";

              # Everything install.sh shells out to, beyond what the
              # minimal ISO already carries (lspci, dmidecode and sgdisk
              # are the easy ones to miss).
              # openssl/whois(python3 fallback) are for password hashing
              # (mkpasswd / openssl passwd -6 / crypt), python3 also
              # drives the flake.nix entry generator.
              environment.systemPackages = with pkgs; [
                bcachefs-tools
                curl
                dmidecode
                dosfstools # mkfs.vfat
                efibootmgr
                git
                gptfdisk # sgdisk
                openssl # openssl passwd -6
                parted
                pciutils # lspci
                python3
                usbutils
                whois # mkpasswd
              ];

              # Keep NetworkManager enabled for easy Wi-Fi connectivity in the installer
              networking.networkmanager.enable = true;
            }
          )
        ];
      };
    };
}
