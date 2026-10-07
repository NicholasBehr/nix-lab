{
  # The ephemeral root is rolled back at boot, so keep the complete service
  # log hierarchy on persistent storage. This includes the system journal and
  # file-based logs such as nginx's access log.
  environment.persistence."/persist128".directories = [
    "/var/log"
  ];

  services.journald.extraConfig = ''
    Storage=persistent
    Compress=yes
    SystemMaxUse=1G
    SystemKeepFree=2G
    MaxRetentionSec=30day
    MaxFileSec=1day
  '';
}
