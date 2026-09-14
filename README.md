# Nix configuration

This repository contains a NixOS configuration flake.

## Pre-commit checks

Install the hooks once:

```bash
pre-commit install
```

The hooks run three read-only checks:

- Alejandra checks Nix formatting.
- Statix checks Nix lint issues.
- `nix flake check --no-build` evaluates the flake.

The hooks report problems but do not modify files. To fix issues locally, run:

```bash
nix fmt
nix run nixpkgs#statix -- fix
pre-commit run --all-files
```

The first two commands may modify files. The final command verifies that the
configuration passes all checks.

The formatting and flake checks use tools declared by the flake. The Statix
hook may download Statix the first time it runs.

Run the checks manually at any time with:

```bash
pre-commit run --all-files
```
