{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.sops;
  users = config.users.users;
  sops-install-secrets = (pkgs.callPackage ../.. {}).sops-install-secrets;
  regularSecrets = lib.filterAttrs (_: v: !v.neededForUsers) cfg.secrets;
  secretsForUsers = lib.filterAttrs (_: v: v.neededForUsers) cfg.secrets;
  secretType = types.submodule ({ config, ... }: {
    config = {
      sopsFile = lib.mkOptionDefault cfg.defaultSopsFile;
      sopsFileHash = mkOptionDefault (optionalString cfg.validateSopsFiles "${builtins.hashFile "sha256" config.sopsFile}");
    };
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = ''
          Name of the file used in /run/secrets
        '';
      };
      key = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = ''
          Key used to lookup in the sops file.
          No tested data structures are supported right now.
          This option is ignored if format is binary.
        '';
      };
      path = mkOption {
        type = types.str;
        default = if config.neededForUsers then "/run/secrets-for-users/${config.name}" else "/run/secrets/${config.name}";
        defaultText = "/run/secrets-for-users/$name when neededForUsers is set, /run/secrets/$name when otherwise.";
        description = ''
          Path where secrets are symlinked to.
          If the default is kept no symlink is created.
        '';
      };
      format = mkOption {
        type = types.enum ["yaml" "json" "binary"];
        default = cfg.defaultSopsFormat;
        description = ''
          File format used to decrypt the sops secret.
          Binary files are written to the target file as is.
        '';
      };
      mode = mkOption {
        type = types.str;
        default = "0400";
        description = ''
          Permissions mode of the in octal.
        '';
      };
      owner = mkOption {
        type = types.str;
        default = "root";
        description = ''
          User of the file.
        '';
      };
      group = mkOption {
        type = types.str;
        default = users.${config.owner}.group;
        description = ''
          Group of the file.
        '';
      };
      sopsFile = mkOption {
        type = types.path;
        defaultText = "\${config.sops.defaultSopsFile}";
        description = ''
          Sops file the secret is loaded from.
        '';
      };
      sopsFileHash = mkOption {
        type = types.str;
        readOnly = true;
        description = ''
          Hash of the sops file, useful in <xref linkend="opt-systemd.services._name_.restartTriggers" />.
        '';
      };
      neededForUsers = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enabling this option causes the secret to be decrypted before users and groups are created.
          This can be used to retrieve user's passwords from sops-nix.
          Setting this option moves the secret to /run/secrets-for-users and disallows setting owner and group to anything else than root.
        '';
      };
    };
  });

  manifestFor = suffix: secrets: extraJson: pkgs.writeTextFile {
    name = "manifest${suffix}.json";
    text = builtins.toJSON ({
      secrets = builtins.attrValues secrets;
      # Does this need to be configurable?
      secretsMountPoint = "/run/secrets.d";
      symlinkPath = "/run/secrets";
      gnupgHome = cfg.gnupg.home;
      sshKeyPaths = cfg.gnupg.sshKeyPaths;
      ageKeyFile = cfg.age.keyFile;
      ageSshKeyPaths = cfg.age.sshKeyPaths;
    } // extraJson);
    checkPhase = ''
      ${sops-install-secrets}/bin/sops-install-secrets -check-mode=${if cfg.validateSopsFiles then "sopsfile" else "manifest"} "$out"
    '';
  };

  manifest = manifestFor "" regularSecrets {};
  manifestForUsers = manifestFor "-for-users" secretsForUsers {
    secretsMountPoint = "/run/secrets.d/users"; # TODO can we move this?
    symlinkPath = "/run/secrets-for-users";
  };

in {
  options.sops = {
    secrets = mkOption {
      type = types.attrsOf secretType;
      default = {};
      description = ''
        Path where the latest secrets are mounted to.
      '';
    };

    defaultSopsFile = mkOption {
      type = types.path;
      description = ''
        Default sops file used for all secrets.
      '';
    };

    defaultSopsFormat = mkOption {
      type = types.str;
      default = "yaml";
      description = ''
        Default sops format used for all secrets.
      '';
    };

    validateSopsFiles = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Check all sops files at evaluation time.
        This requires sops files to be added to the nix store.
      '';
    };

    age = {
      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/sops-nix/key.txt";
        description = ''
          Path to age key file used for sops decryption.
        '';
      };

      generateKey = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether or not to generate the age key. If this
          option is set to false, the key must already be
          present at the specified location.
        '';
      };

      sshKeyPaths = mkOption {
        type = types.listOf types.path;
        default = if config.services.openssh.enable then map (e: e.path) (lib.filter (e: e.type == "ed25519") config.services.openssh.hostKeys) else [];
        description = ''
          Paths to ssh keys added as age keys during sops description.
        '';
      };
    };

    gnupg = {
      home = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/root/.gnupg";
        description = ''
          Path to gnupg database directory containing the key for decrypting the sops file.
        '';
      };

      sshKeyPaths = mkOption {
        type = types.listOf types.path;
        default = if config.services.openssh.enable then
                    map (e: e.path) (lib.filter (e: e.type == "rsa") config.services.openssh.hostKeys)
                  else [];
        description = ''
          Path to ssh keys added as GPG keys during sops description.
          This option must be explicitly unset if <literal>config.sops.gnupg.sshKeyPaths</literal> is set.
        '';
      };
    };
  };
  imports = [
    (mkRenamedOptionModule [ "sops" "gnupgHome" ] [ "sops" "gnupg" "home" ])
    (mkRenamedOptionModule [ "sops" "sshKeyPaths" ] [ "sops" "gnupg" "sshKeyPaths" ])
  ];
  config = mkIf (cfg.secrets != {}) {
    assertions = [{
      assertion = cfg.gnupg.home != null || cfg.gnupg.sshKeyPaths != [] || cfg.age.keyFile != null || cfg.age.sshKeyPaths != [];
      message = "No key source configurated for sops";
    } {
      assertion = !(cfg.gnupg.home != null && cfg.gnupg.sshKeyPaths != []);
      message = "Exactly one of sops.gnupg.home and sops.gnupg.sshKeyPaths must be set";
    } {
      assertion = (filterAttrs (_: v: v.owner != "root" || v.group != "root") secretsForUsers) == {};
      message = "neededForUsers cannot be used for secrets that are not root-owned";
    }] ++ optionals cfg.validateSopsFiles (
      concatLists (mapAttrsToList (name: secret: [{
        assertion = builtins.pathExists secret.sopsFile;
        message = "Cannot find path '${secret.sopsFile}' set in sops.secrets.${strings.escapeNixIdentifier name}.sopsFile";
      } {
        assertion =
          builtins.isPath secret.sopsFile ||
          (builtins.isString secret.sopsFile && hasPrefix builtins.storeDir secret.sopsFile);
        message = "'${secret.sopsFile}' is not in the Nix store. Either add it to the Nix store or set sops.validateSopsFiles to false";
      }]) cfg.secrets)
    );

    system.activationScripts = {
      setupSecretsForUsers = mkIf (secretsForUsers != {}) (stringAfter ([ "specialfs" ] ++ optional cfg.age.generateKey "generate-age-key") ''
        echo setting up secrets for users...
        ${optionalString (cfg.gnupg.home != null) "SOPS_GPG_EXEC=${pkgs.gnupg}/bin/gpg"} ${sops-install-secrets}/bin/sops-install-secrets -ignore-passwd ${manifestForUsers}
      '');

      users = mkIf (secretsForUsers != {}) {
        deps = [ "setupSecretsForUsers" ];
      };

      setupSecrets = mkIf (regularSecrets != {}) (stringAfter ([ "specialfs" "users" "groups" ] ++ optional cfg.age.generateKey "generate-age-key") ''
        echo setting up secrets...
        ${optionalString (cfg.gnupg.home != null) "SOPS_GPG_EXEC=${pkgs.gnupg}/bin/gpg"} ${sops-install-secrets}/bin/sops-install-secrets ${manifest}
      '');

      generate-age-key = mkIf (cfg.age.generateKey) (stringAfter [] ''
        if [[ ! -f '${cfg.age.keyFile}' ]]; then
          echo generating machine-specific age key...
          mkdir -p $(dirname ${cfg.age.keyFile})
          # age-keygen sets 0600 by default, no need to chmod.
          ${pkgs.age}/bin/age-keygen -o ${cfg.age.keyFile}
        fi
      '');
    };
  };
}
