let
  nvmeIds = [
    "/dev/disk/by-id/nvme-CT2000P3PSSD8_2339E8794C2C"
    "/dev/disk/by-id/nvme-CT2000P3PSSD8_2414E8A3D454"
    "/dev/disk/by-id/nvme-CT2000P3PSSD8_2414E8A450A5"
    "/dev/disk/by-id/nvme-CT2000P3PSSD8_2436E98ABA2F"
  ];

  hddDataIds = [
    "/dev/disk/by-id/ata-WDC_WD8005FFBX-68CAKN0_WD-AM0ZXRPT"
    "/dev/disk/by-id/ata-WDC_WD8005FFBX-68CAKN0_WD-AM1879GT"
  ];

  hddParityIds = [
    "/dev/disk/by-id/ata-WDC_WD8005FFBX-68CAKN0_WD-AM18T80T"
  ];

  bootMountpoints = builtins.genList (i: "/boot${toString (i + 1)}") (builtins.length nvmeIds);
  nvmeDataMountpoint = "/nvme_data1";
  hddDataMountpoints = builtins.genList (i: "/hdd_data${toString (i + 1)}") (
    builtins.length hddDataIds
  );
  hddParityMountpoints = builtins.genList (i: "/hdd_parity${toString (i + 1)}") (
    builtins.length hddParityIds
  );

  hddIds = hddDataIds ++ hddParityIds;
  hddMountpoints = hddDataMountpoints ++ hddParityMountpoints;
in
{
  inherit
    nvmeIds
    hddDataIds
    hddParityIds
    bootMountpoints
    nvmeDataMountpoint
    hddDataMountpoints
    hddParityMountpoints
    hddIds
    hddMountpoints
    ;
}
