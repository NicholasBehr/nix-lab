{
  config,
  pkgs,
  ...
}: let
  repository = "ssh://o0vaeg3h@o0vaeg3h.repo.borgbase.com/./repo";
  host = "o0vaeg3h.repo.borgbase.com";
  borgStateDirectory = "/persist128/var/lib/borg";
  borg = pkgs.writeShellApplication {
    name = "maintenance-borg";
    runtimeInputs = [pkgs.borgbackup pkgs.coreutils pkgs.openssh];
    text = ''
      export BORG_REPO=${repository}
      export BORG_BASE_DIR=${borgStateDirectory}
      export BORG_PASSCOMMAND="cat ${config.sops.secrets.borg-passphrase.path}"
      export BORG_RSH="ssh -i ${config.sops.secrets.borg-ssh-key.path} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o ServerAliveInterval=10 -o ServerAliveCountMax=30"
      exec borg "$@"
    '';
  };
in {
  sops.secrets = {
    borg-ssh-key = {
      mode = "0400";
    };
    borg-passphrase = {
      mode = "0400";
    };
  };

  # Pin the exact server key whose fingerprint was verified against BorgBase's
  # control panel before deployment. Never learn this key during a backup run.
  programs.ssh.knownHosts.borgbase = {
    hostNames = [host];
    publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCwHsO5g7kAEpqcK4bpHCUKYV1cKCUNwVEVsDQyfj7N8L92E21n+aEhIX2Nh/kFs1W9D/pgsWQBAbco9e/ORuagHrO8hUQtbda5Z31PAo4eipwP17VQr5rF3seaJJNFV72v89PGwMOWQwvoJte+yngC6PYGKJ+w63SRtflihAmf4xa5Tci/f6jbX6t32m2F3bnephVzQO6anGXvGPR8QYQXzSu/27+LaKnLd2Kugb1Ytbo0+6kioa60HWejIZ/mCrCHXYpi0jAllaYEuAsTqFWf/OFUHrKWwRAJD0TV43O1++vLlxY85oQxIgc4oUbm93dXmDBssrTnqqq2jqonteUr";
  };

  environment.systemPackages = [borg];
  systemd.tmpfiles.rules = ["d ${borgStateDirectory} 0700 root root -"];

  homelab.maintenance.archive = [
    ''
      mapfile -d "" -t sources < <(
        ${pkgs.jq}/bin/jq -j '.[] + "\u0000"' "$MAINTENANCE_SOURCES_FILE"
      )
      test "''${#sources[@]}" -gt 0

      # Each declared source is a restore-set boundary. In particular, do not
      # descend from Nextcloud state into its separately declared data bind mount.
      ${borg}/bin/maintenance-borg create \
        --compression auto,zstd \
        --exclude-caches \
        --one-file-system \
        --stats \
        "::maintenance-$(basename "$MAINTENANCE_RUN_DIR")" \
        "''${sources[@]}"

      # This repository is append-only. Prune updates its visible archive set,
      # while physical space is reclaimed later through BorgBase's admin-only
      # compact operation.
      exec ${borg}/bin/maintenance-borg prune \
        --glob-archives 'maintenance-*' \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        --stats
    ''
  ];
}
