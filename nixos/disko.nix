{ lib, ... }:
let
  disks = import ./disks.nix;

  mkNvmeDisk = diskId: bootMountpoint: {
    type = "disk";
    device = diskId;
    content = {
      type = "gpt";
      partitions = {
        esp = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = bootMountpoint;
          };
        };
        zfs = {
          size = "100%";
          content = {
            type = "zfs";
            pool = "zpool";
          };
        };
      };
    };
  };

  mkHddDisk = diskId: hddMountpoint: {
    type = "disk";
    device = diskId;
    content = {
      type = "gpt";
      partitions = {
        storage = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = hddMountpoint;
            extraArgs = [
              "-d"
              "su=1024K,sw=1"
            ];
          };
        };
      };
    };
  };

  nvmeDisks = builtins.listToAttrs (
    lib.imap0 (index: diskId: {
      name = "nvme${toString (index + 1)}";
      value = mkNvmeDisk diskId (builtins.elemAt disks.bootMountpoints index);
    }) disks.nvmeIds
  );

  hddDisks = builtins.listToAttrs (
    lib.imap0 (index: diskId: {
      name = "hdd${toString (index + 1)}";
      value = mkHddDisk diskId (builtins.elemAt disks.hddMountpoints index);
    }) disks.hddIds
  );
in
{
  disko.devices = {
    disk = nvmeDisks // hddDisks;

    zpool = {
      zpool = {
        type = "zpool";
        mode = {
          topology = {
            type = "topology";
            vdev = [
              {
                mode = "mirror";
                members = [
                  "nvme1"
                  "nvme2"
                ];
              }
              {
                mode = "mirror";
                members = [
                  "nvme3"
                  "nvme4"
                ];
              }
            ];

          };
        };
        rootFsOptions = {
          acltype = "posixacl";
          atime = "off";
          compression = "lz4";
          xattr = "sa";
        };

        datasets = {
          # Ephemeral root: reset to the blank snapshot on reinstall/rebuild.
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            postCreateHook = "zfs snapshot zpool/root@blank";
          };

          # Package store on ZFS for fast snapshots and rollback-friendly rebuilds.
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options.compression = "zstd";
          };

          # Persistence tiers for the impermanence module.
          # - persist16: small, metadata-heavy state e.g. MySQL DB files.
          persist16 = {
            type = "zfs_fs";
            mountpoint = "/persist16";
            options.recordsize = "16K";
          };

          # - persist128: general persistent state e.g. /var/lib and /var/log.
          persist128 = {
            type = "zfs_fs";
            mountpoint = "/persist128";
            options.recordsize = "128K";
          };

          # - persist1024: large sequential blobs e.g. InfluxDB TSDB files.
          persist1024 = {
            type = "zfs_fs";
            mountpoint = "/persist1024";
            options.recordsize = "1024K";
          };

          # Scratch/high-throughput NVMe target for mergerFS and SnapRAID staging.
          nvme_data1 = {
            type = "zfs_fs";
            mountpoint = disks.nvmeDataMountpoint;
            options.recordsize = "1024K";
            options.atime = "on";
            options.relatime = "on";
          };

          # Swap is ephemeral and encrypted with a random key at boot.
          "swap" = {
            type = "zfs_volume";
            size = "16G";
            content = {
              type = "swap";
              randomEncryption = true;
            };
          };
        };
      };
    };
  };
}
