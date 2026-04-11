{
  description = "Home Lab Infra Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    homeConfigurations.server = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;

      modules = [
        ./home.nix
      ];
    };
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.git
        pkgs.openssh
      ];

      shellHook = ''
        export PATH=$PWD/scripts:$PATH
      '';
    };
  };
}
