{
  description = "debuginfo-zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      zig,
      ...
    }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
      lib = nixpkgs.lib;

      fun_zig_0_17 =
        pkgs:
        (
          let
            dev_zig = zig.packages.${pkgs.stdenv.hostPlatform.system}."master-2026-06-19" // {
              meta = {
                platforms = pkgs.lib.platforms.all;
                broken = false;
                maintainers = [ ];
              };
            };
            dev_zig_hook = pkgs.zig.hook.override { zig = dev_zig; };
          in
          dev_zig // { hook = dev_zig_hook; }
        );

      fun_libdebuginfod = pkgs: attrs: pkgs.callPackage ./pkg.nix attrs;

      overlay = (
        final: prev: {
          dev_zig_0_17 = (fun_zig_0_17 prev);
          libdebuginfod-zig-static = (
            fun_libdebuginfod prev {
              flags = [ "-Dlinkage=static" ];
            }
          );
          libdebuginfod-zig-dynamic = (
            fun_libdebuginfod prev {
              flags = [ "-Dlinkage=dynamic" ];
            }
          );
        }
      );

      fun_pkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            overlay
          ];
        };
    in
    {
      overlays.default = overlay;
      packages = forAllSystems (
        system:
        let
          pkgs = (fun_pkgs system);
        in
        {
          static = pkgs.libdebuginfod-zig-static;
          dynamic = pkgs.libdebuginfod-zig-dynamic;
          default = self.packages.${system}.dynamic;
          pkgsCross = pkgs.pkgsCross;
        }
      );
      develop = forAllSystems (
        system:
        let
          pkgs = (fun_pkgs system);
        in
        {
          default = pkgs.dev_zig_0_17;
        }
      );
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
