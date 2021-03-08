{ mkNomadJob, domain, lib, mantis, mantis-source, mantis-faucet
, mantis-faucet-source, morpho-node, morpho-source, dockerImages
, mantis-explorer }@args:
let
  namespaces = {
    mantis-evm = import ./mantis (args // {
      namespace = "mantis-evm";
      publicPortStart = 11000;
      domainSuffix = "-evm.${domain}";
      mantisImage = dockerImages.mantis-evm;
      explorerImage = dockerImages.mantis-explorer-evm;
      faucetImage = dockerImages.mantis-faucet-web-evm;
      domainTitle = "EVM";

      extraConfig = ''
        mantis.consensus {
          protocol = "ethash"
        }
        mantis.vm {
          mode = "internal"
        }
      '';
    });
    mantis-iele = import ./mantis (args // {
      namespace = "mantis-iele";
      publicPortStart = 10000;
      domainSuffix = "-iele.${domain}";
      mantisImage = dockerImages.mantis-kevm;
      explorerImage = dockerImages.mantis-explorer-iele;
      faucetImage = dockerImages.mantis-faucet-web-iele;
      domainTitle = "IELE";

      extraConfig = ''
        mantis.vm {
          mode = "external"
          external {
            vm-type = "kevm"
            run-vm = true
            executable-path = "/bin/kevm-vm"
            host = "127.0.0.1"
            port = {{ env "NOMAD_PORT_vm" }}
          }
        }
      '';
    });
    mantis-kevm = import ./mantis (args // {
      namespace = "mantis-kevm";
      publicPortStart = 9000;
      domainSuffix = "-kevm.${domain}";
      mantisImage = dockerImages.mantis-kevm;
      explorerImage = dockerImages.mantis-explorer-kevm;
      faucetImage = dockerImages.mantis-faucet-web-kevm;
      domainTitle = "KEVM";

      extraConfig = ''
        mantis.consensus {
          protocol = "restricted-ethash"
        }
        mantis.vm {
          mode = "external"
          external {
            vm-type = "kevm"
            run-vm = true
            executable-path = "/bin/kevm-vm"
            host = "127.0.0.1"
            port = {{ env "NOMAD_PORT_vm" }}
          }
        }
      '';
    });
  };
in builtins.foldl' (s: v: s // v) {} (builtins.attrValues namespaces)