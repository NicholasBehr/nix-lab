{
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@nicholasbehr.ch";
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # ACME account data and certificates must survive the ephemeral-root rollback.
  environment.persistence."/persist128".directories = [
    "/var/lib/acme"
  ];
}
