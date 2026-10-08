{config, ...}: {
  homelab.maintenance = {
    enable = true;
    stateDirectory = "/persist128/var/lib/maintenance";
    timer = {
      # The Borg destination/credentials are not configured yet. Never take
      # applications offline for a run which cannot archive their restore set.
      enable = config.homelab.maintenance.archive != [];
      calendar = "*-*-* 02:00:00";
    };
  };
}
