{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "tier-mover";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = true;
  meta.platforms = lib.platforms.linux;
}
