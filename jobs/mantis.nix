{ mkNomadJob, systemdSandbox, writeShellScript, writeText, coreutils, lib
, cacert, jq, gnused, mantis, mantis-source, dnsutils, gnugrep, iproute, lsof
, netcat, nettools, procps, curl, gawk }:
let
  minerResources = {
    # For c5.2xlarge in clusters/mantis/testnet/default.nix, the url ref below
    # provides 3.4 GHz * 8 vCPU = 27.2 GHz max.  80% is 21760 MHz.
    # Allocating by vCPU or core quantity not yet available.
    # Ref: https://github.com/hashicorp/nomad/blob/master/client/fingerprint/env_aws.go
    cpu = 21760;
    memoryMB = 8 * 1024;
    networks = [{
      reservedPorts = [
        {
          label = "rpc";
          value = 8546;
        }
        {
          label = "server";
          value = 9076;
        }
        {
          label = "metrics";
          value = 13798;
        }
      ];
    }];
  };

  passiveResources = {
    # For c5.2xlarge in clusters/mantis/testnet/default.nix, the url ref below
    # provides 3.4 GHz * 8 vCPU = 27.2 GHz max.  80% is 21760 MHz.
    # Allocating by vCPU or core quantity not yet available.
    # Ref: https://github.com/hashicorp/nomad/blob/master/client/fingerprint/env_aws.go
    cpu = 500;
    memoryMB = 3 * 1024;
    networks = [{
      dynamicPorts = [ { label = "rpc"; } { label = "server"; } ];
      reservedPorts = [{
        label = "metrics";
        value = 13798;
      }];
    }];
  };

  ephemeralDisk = {
    # Std client disk size is set as gp2, 100 GB SSD in bitte at
    # modules/terraform/clients.nix
    sizeMB = 10 * 1000;
    # migrate = true;
    # sticky = true;
  };

  run-mantis = { requiredPeerCount }:
    writeShellScript "mantis" ''
      set -exuo pipefail
      export PATH=${lib.makeBinPath [ jq coreutils gnused gnugrep mantis ]}

      mkdir -p "$NOMAD_TASK_DIR"/{mantis,rocksdb,logs}
      cd "$NOMAD_TASK_DIR"

      set +x
      echo "waiting for ${toString requiredPeerCount} peers"
      until [ "$(grep -c enode mantis.conf)" -ge ${
        toString requiredPeerCount
      } ]; do
        sleep 0.1
      done
      set -x

      cp "mantis.conf" running.conf

      chown --reference . --recursive . || true

      env

      ulimit -c unlimited

      exec mantis "-Duser.home=$NOMAD_TASK_DIR" "-Dconfig.file=$NOMAD_TASK_DIR/running.conf"
    '';

  env = {
    # Adds some extra commands to the store and path for debugging inside
    # nomad jobs with `nomad alloc exec $ALLOC_ID /bin/sh`
    PATH = lib.makeBinPath [
      coreutils
      curl
      dnsutils
      gawk
      gnugrep
      iproute
      jq
      lsof
      netcat
      nettools
      procps
    ];
  };

  templatesFor = { name ? null, mining-enabled ? false }:
    let secret = key: ''{{ with secret "${key}" }}{{.Data.data.value}}{{end}}'';
    in [{
      data = ''
        include "${mantis}/conf/testnet-internal.conf"

        logging.json-output = true
        logging.logs-file = "logs"

        mantis.blockchains.testnet-internal.bootstrap-nodes = [
          {{ range service "mantis-miner" -}}
            "enode://  {{- with secret (printf "kv/data/nomad-cluster/testnet/%s/enode-hash" .ServiceMeta.Name) -}}
              {{- .Data.data.value -}}
              {{- end -}}@{{ .Address }}:{{ .Port }}",
          {{ end -}}
        ]

        mantis.consensus.coinbase = "{{ with secret "kv/data/nomad-cluster/testnet/${name}/coinbase" }}{{ .Data.data.value }}{{ end }}"
        mantis.node-key-file = "{{ env "NOMAD_SECRETS_DIR" }}/secret-key"
        mantis.datadir = "{{ env "NOMAD_TASK_DIR" }}/mantis"
        mantis.ethash.ethash-dir = "{{ env "NOMAD_TASK_DIR" }}/ethash"
        mantis.metrics.enabled = true
        mantis.metrics.port = {{ env "NOMAD_PORT_metrics" }}
        mantis.network.rpc.http.interface = "0.0.0.0"
        mantis.network.rpc.http.port = {{ env "NOMAD_PORT_rpc" }}
        mantis.network.server-address.port = {{ env "NOMAD_PORT_server" }}
      '';
      destination = "local/mantis.conf";
      changeMode = "noop";
    }] ++ (lib.optional mining-enabled {
      data = ''
        ${secret "kv/data/nomad-cluster/testnet/${name}/secret-key"}
        ${secret "kv/data/nomad-cluster/testnet/${name}/enode-hash"}
      '';
      destination = "secrets/secret-key";
    });

  mkMantis = { name, resources, ephemeralDisk, count ? 1, templates, serviceName
    , tags ? [ ], extraEnvironmentVariables ? [ ], meta ? { }, constraints ? [ ]
    , requiredPeerCount }: {
      inherit ephemeralDisk count constraints;

      reschedulePolicy = {
        attempts = 0;
        unlimited = false;
      };

      tasks.${name} = systemdSandbox {
        inherit name env resources templates extraEnvironmentVariables;
        command = run-mantis { inherit requiredPeerCount; };
        vault.policies = [ "nomad-cluster" ];

        restartPolicy = {
          interval = "30m";
          attempts = 1;
          delay = "1m";
          mode = "fail";
        };

        services.${serviceName} = {
          tags = [ serviceName mantis-source.rev ] ++ tags;
          meta = {
            inherit name;
            publicIp = "\${attr.unique.platform.aws.public-ipv4}";
          } // meta;
          portLabel = "server";
          checks = [{
            type = "http";
            path = "/healthcheck";
            portLabel = "rpc";

            checkRestart = {
              limit = 5;
              grace = "300s";
              ignoreWarnings = false;
            };
          }];
        };
      };
    };

  mkMiner = { name, publicPort, requiredPeerCount ? 0, instanceId ? null }:
    lib.nameValuePair name (mkMantis {
      resources = minerResources;
      inherit ephemeralDisk name requiredPeerCount;
      templates = templatesFor {
        inherit name;
        mining-enabled = true;
      };
      serviceName = "mantis-miner";
      tags = [ "public" name ];
      meta = {
        path = "/";
        domain = "${name}.mantis.ws";
        port = toString publicPort;
      };
      constraints = if instanceId != null then [{
        attribute = "\${attr.unique.platform.aws.instance-id}";
        value = instanceId;
      }] else
        [ ];
    });

  mkPassive = count:
    mkMantis {
      name = "mantis-passive";
      serviceName = "mantis-passive";
      resources = passiveResources;
      tags = [ "passive" ];
      inherit count;
      requiredPeerCount = builtins.length miners;
      ephemeralDisk = { sizeMB = 1000; };
      templates = [{
        data = ''
          include "${mantis}/conf/testnet-internal.conf"

          logging.json-output = true
          logging.logs-file = "logs"

          mantis.blockchains.testnet-internal.bootstrap-nodes = [
            {{ range service "mantis-miner" -}}
              "enode://  {{- with secret (printf "kv/data/nomad-cluster/testnet/%s/enode-hash" .ServiceMeta.Name) -}}
                {{- .Data.data.value -}}
                {{- end -}}@{{ .Address }}:{{ .Port }}",
            {{ end -}}
          ]

          mantis.consensus.mining-enabled = false
          mantis.datadir = "{{ env "NOMAD_TASK_DIR" }}/mantis"
          mantis.ethash.ethash-dir = "{{ env "NOMAD_TASK_DIR" }}/ethash"
          mantis.metrics.enabled = true
          mantis.metrics.port = {{ env "NOMAD_PORT_metrics" }}
          mantis.network.rpc.http.interface = "0.0.0.0"
          mantis.network.rpc.http.port = {{ env "NOMAD_PORT_rpc" }}
          mantis.network.server-address.port = {{ env "NOMAD_PORT_server" }}
        '';
        changeMode = "noop";
        destination = "local/mantis.conf";
      }];

      constraints = lib.forEach miners (miner: {
        attribute = "\${attr.unique.platform.aws.instance-id}";
        operator = "!=";
        value = miner.instanceId;
      });
    };

  miners = [
    {
      name = "mantis-1";
      requiredPeerCount = 0;
      publicPort = 9001; # Make sure to also change it in ingress.nix
      instanceId = "i-016b85976830d3010";
    }
    {
      name = "mantis-2";
      requiredPeerCount = 1;
      publicPort = 9002;
      instanceId = "i-016ff18ce9d37055d";
    }
    {
      name = "mantis-3";
      requiredPeerCount = 2;
      publicPort = 9003;
      instanceId = "i-027fdf934cd365575";
    }
    {
      name = "mantis-4";
      requiredPeerCount = 3;
      publicPort = 9004;
      instanceId = "i-04832eb69076aef14";
    }
    {
      name = "mantis-5";
      requiredPeerCount = 4;
      publicPort = 9005;
      instanceId = "i-0917601141a6187fc";
    }
    {
      name = "mantis-6";
      requiredPeerCount = 5;
      publicPort = 9006;
      instanceId = "i-0bda1c2cb52b9ac3e";
    }
    {
      name = "mantis-7";
      requiredPeerCount = 6;
      publicPort = 9007;
      instanceId = "i-0d250b307a248218e";
    }
    {
      name = "mantis-8";
      requiredPeerCount = 7;
      publicPort = 9008;
      instanceId = "i-0df761c9a86cd3df3";
    }
    {
      name = "mantis-9";
      requiredPeerCount = 8;
      publicPort = 9009;
      instanceId = "i-0f85d80501cd0dceb";
    }
    {
      name = "mantis-10";
      requiredPeerCount = 9;
      publicPort = 9010;
      instanceId = "i-0fe5414a46df1d268";
    }
  ];
in {
  mantis = mkNomadJob "mantis" {
    datacenters = [ "us-east-2" "eu-central-1" ];
    type = "service";

    update = {
      maxParallel = 1;
      # healthCheck = "checks"
      minHealthyTime = "10s";
      healthyDeadline = "5m";
      progressDeadline = "10m";
      autoRevert = true;
      autoPromote = false;
      canary = 0;
      stagger = "30s";
    };

    taskGroups = (lib.listToAttrs (map mkMiner miners)) // {
      mantis-passive = mkPassive 2;
    };
  };
}
