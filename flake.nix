{
  description = "Custom NixOS Installer ISO with Bcachefs Support";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    {
      nixosConfigurations.iso = nixpkgs.lib.nixosSystem {
        # Change "x86_64-linux" to "aarch64-linux" if your Chromebook uses an ARM processor
        system = "x86_64-linux";

        modules = [
          # Official minimal installation CD profile, using the current mainline
          # kernel and explicitly without ZFS. The bcachefs module in the default
          # 6.18 kernel does not compile against that kernel's inode API, while
          # the same module builds against linuxPackages_latest.
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal-new-kernel-no-zfs.nix"

          (
            {
              pkgs,
              ...
            }:
            {
              # The live kernel needs bcachefs so the target can be formatted.
              boot.supportedFilesystems = [ "bcachefs" ];

              environment.etc."nixos-installer/install.sh".source = ./install.sh;

              # Everything install.sh shells out to, beyond what the minimal ISO
              # already carries. The installer loops over module files itself;
              # it does not need python or any repo-specific tooling.
              environment.systemPackages = with pkgs; [
                bcachefs-tools
                curl
                dmidecode
                dosfstools # mkfs.vfat
                efibootmgr
                git
                gptfdisk # sgdisk
                openssl # openssl passwd -6
                parted # partprobe
                pciutils # lspci
                usbutils
                util-linux # lsblk, wipefs, mount, swapon, udevadm
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
