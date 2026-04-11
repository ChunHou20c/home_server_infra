{
  description = "Home Lab Infra Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";

  };

  outputs = { nixpkgs, home-manager, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
	let
	  pkgs = import nixpkgs {
	    inherit system;
	  };
	in {
	  homeConfigurations.server = home-manager.lib.homeManagerConfiguration {
	  inherit pkgs;

	  modules = [
	    ./home.nix
	  ];
	  };
	});
}
