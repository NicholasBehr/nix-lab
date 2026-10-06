{
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # Baseline headers only. CSP and framing rules stay per-application.
    # Note: nginx drops these in any scope that defines its own add_header.
    appendHttpConfig = ''
      add_header Strict-Transport-Security "max-age=31536000" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    '';

    # Catch-all: close HTTP requests for unknown hosts and abort TLS
    # handshakes for unknown server names.
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };
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
