{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "maintenance-runner";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = true;
  meta.mainProgram = "maintenance-runner";
  meta.platforms = lib.platforms.linux;
}
