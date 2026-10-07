# Reusable mechanisms; host/application policy lives in nixos/ and services/.
{
  bulk-storage = import ./bulk-storage.nix;
  tier-mover = import ./tier-mover.nix;
}
