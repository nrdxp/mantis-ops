{
  description = "Bitte for Mantis";

  inputs = {
    bitte.url = "github:input-output-hk/bitte/terraform-state-in-vault";
    # bitte.url = "path:/home/craige/source/IOHK/bitte";
    # bitte.url = "path:/home/jlotoski/work/iohk/bitte-wt/bitte";
    # bitte.url = "path:/home/manveru/github/input-output-hk/bitte";
    nixpkgs.follows = "bitte/nixpkgs";
    terranix.follows = "bitte/terranix";
    utils.follows = "bitte/utils";
    ops-lib.url = "github:input-output-hk/ops-lib/zfs-image?dir=zfs";
    inclusive.follows = "bitte/inclusive";
    morpho-node.url = "github:input-output-hk/ECIP-Checkpointing/master";
    mantis-explorer.url = "github:input-output-hk/mantis-explorer";
    mantis-faucet-web.url = "github:input-output-hk/mantis-faucet-web";
  };

  outputs = { self, nixpkgs, ops-lib, bitte, ... }@inputs:
    let
      hashiStack = bitte.mkHashiStack {
        flake = self;
        rootDir = ./.;
        inherit pkgs;
        domain = "portal.dev.cardano.org";
      };

      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [
          (final: prev: { inherit (hashiStack) clusters dockerImages; })
          bitte.overlay.x86_64-linux
          (import ./overlay.nix inputs)
        ];
      };

      nixosConfigurations = hashiStack.nixosConfigurations;
    in {
      inherit nixosConfigurations;
      inherit (hashiStack) nomadJobs;
      clusters.x86_64-linux = hashiStack.clusters;
      legacyPackages.x86_64-linux = pkgs;
      devShell.x86_64-linux = pkgs.devShell;
      hydraJobs.x86_64-linux = {
        inherit (pkgs)
          devShellPath bitte nixFlakes sops
          terraform-with-plugins cfssl consul nomad vault-bin cue grafana
          haproxy grafana-loki victoriametrics
          ;
      } // (pkgs.lib.mapAttrs (_: v: v.config.system.build.toplevel)
        nixosConfigurations);
    };
}
