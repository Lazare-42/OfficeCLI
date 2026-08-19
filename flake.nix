{
  description = "OfficeCLI — Office suite CLI for AI agents (docx/xlsx/pptx). Wraps our patched prebuilt release binary. (wealthfolio branch: dedicated lineage, see note below.)";

  # NOTE: this flake fetches a PREBUILT release binary; it is NOT built from
  # this repo's .NET source (that would need a dotnet-sdk_10 + nuget-deps flake
  # — still the eventual migration). It used to fetch UPSTREAM's iOfficeAI
  # asset, but the fork now carries patches upstream has not taken, so it
  # fetches OUR OWN release instead — see `owner` below.
  #
  # Cutting a patched build (the whole loop, because getting it wrong ships a
  # silent no-op deploy):
  #   1. commit the source change here
  #   2. dotnet publish -c Release -r linux-x64   (self-contained single-file)
  #   3. gh release create v<version> --repo Lazare-42/OfficeCLI <binary>
  #      with the asset named exactly `officecli-linux-x64`
  #   4. edit `version` + `sha256` below to match, commit
  #   5. `nix flake update officecli` in nixos-config, then rebuild
  # Steps 1-2 alone change NOTHING on the host: git+file:// builds from the
  # COMMITTED state, and the binary still comes from the release asset, so a
  # source commit without a matching release is invisible to the deploy.
  #
  # The release repo must stay PUBLIC: nixos-rebuild fetches as the root
  # nix-daemon, which holds no GitHub credentials, so a private asset 404s at
  # deploy time rather than at eval time.
  #
  # --- wealthfolio branch note ---
  # This branch exists so nixos-config can wire a package for wealthfolio's
  # officecli-http bridge (modules/services/officecli-http.nix) WITHOUT
  # touching the shared officecli package that modules/packages.nix +
  # mcpproxy.nix (every Claude Code session on the box) depend on. At this
  # checkpoint it is a pure repackaging with ZERO functional change: the
  # v1.0.129-wealthfolio.1 release re-publishes the IDENTICAL
  # officecli-linux-x64 asset from v1.0.129-mcpfix.1 (same sha256 below), just
  # under a distinct tag targeting this branch. `overlays.default` exposes the
  # attribute as `officecli-wealthfolio`, NOT `officecli` — if it reused the
  # `officecli` name, applying both this and the `main`-branch overlay in
  # nixos-config's `nixpkgs.overlays` list would have the later one silently
  # clobber `pkgs.officecli` for the shared/general path. Future
  # wealthfolio-specific efficiency changes land as commits on this branch,
  # each cut through the same release procedure below under a new
  # `1.0.129-wealthfolio.N` (or higher) tag.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Our patched build of upstream 1.0.129. Carries the MCP fixes in
      # 9ae8d2e (stdin-under-MCP deadlock, per-command timeout, mmdc pipe
      # drain); upstream v1.0.144 still ships the first two, so do NOT
      # "upgrade" this to a plain upstream tag without re-porting them.
      version = "1.0.129-wealthfolio.1";
      owner = "Lazare-42";

      # Per-system release asset name + sha256.
      assets = {
        x86_64-linux = {
          name = "officecli-linux-x64";
          sha256 = "866f5cb72c9315db50426603635c82aff3747f0a7bc18e6d03a58aefea77c6f6";
        };
      };

      mkOfficecli = pkgs:
        let
          sys = pkgs.stdenv.hostPlatform.system;
          asset = assets.${sys} or (throw "officecli: unsupported system ${sys}");

          # .NET single-file self-contained app. It must NOT be modified in any way:
          # patchelf (autoPatchelf) OR nix's default fixup (strip / --shrink-rpath)
          # rewrites the ELF and shifts the appended single-file bundle, corrupting
          # it at runtime ("Arithmetic overflow while reading bundle"). So install
          # the release binary BYTE-FOR-BYTE with `dontFixup`, then run it inside an
          # FHS env (buildFHSEnv, below) which supplies a real /lib64 loader + the
          # .NET runtime libs — instead of patching the binary. (nix-ld would be
          # lighter but is not enabled on this host: /lib64/ld-linux is the default
          # error stub, not the nix-ld shim.)
          bundle = pkgs.stdenvNoCC.mkDerivation {
            pname = "officecli-bundle";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/${owner}/OfficeCLI/releases/download/v${version}/${asset.name}";
              inherit (asset) sha256;
            };
            dontUnpack = true;
            dontFixup = true; # keep the single-file bundle byte-for-byte
            installPhase = "install -Dm755 $src $out/bin/officecli";
          };
        in
        pkgs.buildFHSEnv {
          name = "officecli";
          # Libs the runtime-extracted native .NET assemblies dlopen. buildFHSEnv
          # already provides glibc + the /lib64 loader; these cover the rest.
          # (Add `chromium` here if `officecli view screenshot` is ever needed — it
          # shells out to a headless browser for PNG rendering.)
          targetPkgs = p: (with p; [ stdenv.cc.cc.lib zlib openssl icu ]);
          runScript = pkgs.writeShellScript "officecli-run" ''
            export OFFICECLI_SKIP_UPDATE=1
            exec ${bundle}/bin/officecli "$@"
          '';
          meta = {
            description = "Office suite CLI for AI agents — create/read/modify/render docx, xlsx, pptx";
            homepage = "https://officecli.ai";
            license = pkgs.lib.licenses.asl20;
            mainProgram = "officecli";
            platforms = builtins.attrNames assets;
          };
        };
    in
    {
      # NOT `officecli` — see the wealthfolio-branch note above.
      overlays.default = final: _prev: { officecli-wealthfolio = mkOfficecli final; };

      packages.x86_64-linux.default =
        mkOfficecli (import nixpkgs { system = "x86_64-linux"; });
    };
}
