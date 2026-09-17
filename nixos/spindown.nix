{ pkgs, ... }:
let
  disks = import ./disks.nix;
  hddStandbyTimeout = "60";
in
{
  systemd.services.hdd-spindown = {
    description = "Apply standby timeout to bulk HDDs";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.hdparm
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      for disk in ${builtins.concatStringsSep " " (map (disk: "'${disk}'") disks.hddIds)}; do
        if [ -e "$disk" ]; then
          hdparm -S ${hddStandbyTimeout} "$disk" >/dev/null
        fi
      done
    '';
  };
}