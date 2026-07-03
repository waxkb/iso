{
  description = "Custom NixOS Installer ISO with Bcachefs Support";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    {
      nixosConfigurations.iso = nixpkgs.lib.nixosSystem {
        # Change "x86_64-linux" to "aarch64-linux" if your Chromebook uses an ARM processor
        system = "x86_64-linux";

        modules = [
          # Pulls in the official minimal installation CD configuration profile
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"

          (
            { pkgs, ... }:
            {
              # Force the live kernel to build and include the out-of-tree bcachefs module
              boot.supportedFilesystems = [ "bcachefs" ];

              # Bake the userspace utilities directly into the live system PATH
              environment.systemPackages = [ pkgs.bcachefs-tools ];

              # Keep NetworkManager enabled for easy Wi-Fi connectivity in the installer
              networking.networkmanager.enable = true;
              networking.wireless.enable = false;
            }
          )
        ];
      };
    };
}
