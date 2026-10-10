# PostgreSQL is host infrastructure shared by applications, not owned by any
# individual service. Keep its major version and on-disk state when an
# application is disabled or removed.
{
  lib,
  pkgs,
  ...
}: {
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    settings.listen_addresses = lib.mkForce ""; # Unix sockets only.
  };

  environment.persistence."/persist16".directories = [
    {
      directory = "/var/lib/postgresql";
      user = "postgres";
      group = "postgres";
      mode = "0750";
    }
  ];
}
