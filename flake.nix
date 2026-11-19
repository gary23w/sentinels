# garrett, the agent of sentinels, for Nix: built from source (rust/) the way the release workflow builds it, on
# Linux and macOS.
#
#   nix profile install github:gary23w/sentinels                the newest commit on main
#   nix profile install github:gary23w/sentinels/v<version>     one release
#   nix run github:gary23w/sentinels -- version
#
# It puts the program in place and sets up no service: nothing is started.
#
# There is no NixOS module. On Linux the agent runs ip, ss and nft only from the folders other systems keep them in
# (rust/src/tool.rs), and trusts a program as installed by the system only when it runs from one of the usual
# system folders (rust/src/score.rs). NixOS keeps all of its programs in the Nix store instead. The agent also
# updates itself by replacing its own program file, which the store does not allow.
#
# verify.yml builds this on each kind of machine it is for, and checks that flake.lock is committed and current.
{
  description = "garrett, the agent of sentinels";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Nixpkgs 26.11 no longer builds for Intel Macs. 26.05 is the last release that does, and this branch of it is
    # the one Nixpkgs itself tells flakes on x86_64-darwin to use.
    nixpkgs-intel-mac.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-intel-mac,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      pkgsFor =
        system: (if system == "x86_64-darwin" then nixpkgs-intel-mac else nixpkgs).legacyPackages.${system};
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f system (pkgsFor system));

      # Built as release.yml builds it (cargo build --release --locked, with no extra features), for the system it is
      # asked for, and linked the way Nixpkgs links its programs (the release's Linux files are linked statically,
      # with musl). The crates are the ones Cargo.lock names, all from crates.io, so there is no git dependency to
      # give a hash for. They need nothing beyond a C compiler (ring), which every Nixpkgs build already has.
      garrettPackage =
        { lib, rustPlatform }:
        rustPlatform.buildRustPackage {
          pname = "garrett";
          version = (lib.importTOML ./rust/Cargo.toml).package.version;
          src = ./rust;
          cargoLock.lockFile = ./rust/Cargo.lock;
          cargoBuildFlags = [ "--locked" ];
          # release.yml and verify.yml run the tests on Linux and macOS for every commit. Some of them need what a
          # build sandbox does not have: one reads the service's signal table from server/, outside rust/, and
          # another runs ps.
          doCheck = false;
          # Like every package of garrett, it comes with the licences of the libraries built into it.
          postInstall = ''
            install -Dm644 NOTICES.md $out/share/doc/garrett/NOTICES.md
          '';
          meta = {
            description = "garrett, the agent of sentinels";
            homepage = "https://garrettstimpson.ca/";
            downloadPage = "https://github.com/gary23w/sentinels";
            license = lib.licenses.mit;
            mainProgram = "garrett";
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
          };
        };
    in
    {
      packages = forEachSystem (
        system: pkgs:
        let
          garrett = pkgs.callPackage garrettPackage { };
        in
        {
          inherit garrett;
          default = garrett;
        }
      );

      apps = forEachSystem (
        system: pkgs: {
          default = {
            type = "app";
            program = pkgs.lib.getExe self.packages.${system}.garrett;
            meta.description = "garrett, the agent of sentinels";
          };
        }
      );
    };
}
