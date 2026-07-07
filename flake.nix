{
  description = "OfficeCLI — Office suite CLI for AI agents (docx/xlsx/pptx). Wraps the upstream prebuilt release binary.";

  # NOTE: this fork (Lazare-42/OfficeCLI) cuts no releases of its own, so the
  # flake fetches the UPSTREAM iOfficeAI release binary. It is NOT built from
  # this repo's .NET source (that would need a dotnet-sdk_10 + nuget-deps flake —
  # a future migration if/when we patch the fork). "Bumping" officecli = edit
  # `version` + `sha256` below (from the release SHA256SUMS), commit, then
  # `nix flake update officecli` in nixos-config. git+file:// builds from the
  # COMMITTED state, so uncommitted edits here are ignored.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      version = "1.0.129";

      # Per-system release asset name + sha256 (from the release SHA256SUMS).
      assets = {
        x86_64-linux = {
          name = "officecli-linux-x64";
          sha256 = "1e44357f86b4c664b2e49d18b3b8e2d17947fa4d45b47a1d725a58c65db34159";
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
              url = "https://github.com/iOfficeAI/OfficeCLI/releases/download/v${version}/${asset.name}";
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
      overlays.default = final: _prev: { officecli = mkOfficecli final; };

      packages.x86_64-linux.default =
        mkOfficecli (import nixpkgs { system = "x86_64-linux"; });
    };
}
