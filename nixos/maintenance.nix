_: {
  homelab.maintenance = {
    enable = true;
    stateDirectory = "/persist128/var/lib/maintenance";
    timer = {
      enable = true;
      calendar = "*-*-* 02:00:00";
    };
  };
}
