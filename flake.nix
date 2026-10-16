{
  description = "Nix flake for macOS League of Legends on Linux via darling-lol with auto-install";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # Run `nix-prefetch-git --url https://github.com/lucannez64/darling-lol --fetch-submodules --fetch-lfs`
      # and replace `rev` and `hash` below.
      darlingLolSrc = pkgs.fetchFromGitHub {
        owner = "lucannez64";
        repo = "darling-lol";
        rev = "HEAD";
        hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        fetchSubmodules = true;
        fetchLFS = true;
      };

      darling-lol = pkgs.darling.overrideAttrs (oldAttrs: {
        pname = "darling-lol";
        version = "0.1.0-unstable-2026-10-16";
        src = darlingLolSrc;

        nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ (with pkgs; [
          cmake
          ninja
          clang
          bison
          flex
          pkg-config
          git
          git-lfs
          python3
        ]);

        buildInputs = (oldAttrs.buildInputs or [ ]) ++ (with pkgs; [
          fuse
          libGL
          libGLU
          libglvnd
          mesa
          vulkan-loader
          cairo
          freetype
          fontconfig
          libtiff
          libjpeg
          giflib
          libxml2
          libbsd
          elfutils
          systemd
          dbus
          libpulseaudio
          ffmpeg
          icu
          libxkbcommon
          xorg.libX11
          xorg.libXcursor
          xorg.libXext
          xorg.libXrandr
          xorg.libxkbfile
        ]);

        cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
          "-DCOMPONENTS=stock"
          "-DGIT_LFS_AVAILABLE=ON"
        ];
      });

      # Automated bootstrap, configuration, and launch script
      lolLauncherBin = pkgs.writeShellApplication {
        name = "lol-darling";
        runtimeInputs = with pkgs; [
          darling-lol
          curl
          unzip
          p7zip
          coreutils
          findutils
          gnugrep
          gnused
        ];
        text = ''
          export DPREFIX="''${DPREFIX:-$HOME/.local/share/lol-darling}"
          CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/lol-darling"
          LOL_REGION="''${LOL_REGION:-euw}" # e.g. euw, eune, na, kr, br, oce
          INSTALLER_URL="https://lol.secure.dyn.riotcdn.net/channels/public/x/installer/current/live.''${LOL_REGION}.zip"
          INSTALLER_ARCHIVE="$CACHE_DIR/live.''${LOL_REGION}.zip"

          mkdir -p "$DPREFIX" "$CACHE_DIR"

          # 1. Initialize the Darling overlay prefix if not yet initialized
          if [ ! -d "$DPREFIX/Applications" ]; then
            echo "[lol-darling] Initializing Darling prefix at $DPREFIX..."
            darling shell /usr/bin/true
          fi

          # Ensure required macOS directory hierarchy exists inside prefix & host ~/Library
          mkdir -p \
            "$DPREFIX/Applications" \
            "$DPREFIX/Users/Shared/Riot Games" \
            "$HOME/Library/Application Support/Riot Games" \
            "$HOME/Library/Application Support/League of Legends" \
            "$HOME/Library/Preferences" \
            "$HOME/Library/Logs/Riot Games"

          # Helper function to pre-configure game.cfg for Darling compatibility
          configure_lol() {
            local cfg_dir="$DPREFIX/Applications/League of Legends.app/Contents/LoL/Config"
            local cfg_file="$cfg_dir/game.cfg"
            mkdir -p "$cfg_dir"

            if [ ! -f "$cfg_file" ]; then
              cat > "$cfg_file" <<EOF
          [General]
          WindowMode=2
          WaitForVerticalSync=0
          enable_shader_cache=1
          PreferOpenGL=1
          MetalBetaTest=0
          DX11BetaTest=0
          EOF
              echo "[lol-darling] Wrote default Darling-compatible game.cfg"
            fi
          }

          # 2. Auto-download and run the macOS Riot installer if League isn't installed yet
          if [ ! -d "$DPREFIX/Applications/League of Legends.app" ] && \
             [ ! -d "$DPREFIX/Users/Shared/Riot Games/Riot Client.app" ]; then
            echo "[lol-darling] League of Legends not found in prefix. Starting auto-installer..."

            if [ ! -f "$INSTALLER_ARCHIVE" ]; then
              echo "[lol-darling] Downloading macOS installer for region '$LOL_REGION'..."
              curl -fL --retry 3 -o "$INSTALLER_ARCHIVE.part" "$INSTALLER_URL"
              mv "$INSTALLER_ARCHIVE.part" "$INSTALLER_ARCHIVE"
            fi

            TMP_EXTRACT="$(mktemp -d "$CACHE_DIR/extract.XXXXXX")"
            trap 'rm -rf "$TMP_EXTRACT"' EXIT

            echo "[lol-darling] Extracting installer archive..."
            unzip -q -o "$INSTALLER_ARCHIVE" -d "$TMP_EXTRACT" || 7z x "$INSTALLER_ARCHIVE" -o"$TMP_EXTRACT" -y

            # Handle either direct .app inside .zip or nested .dmg
            DMG_FILE="$(find "$TMP_EXTRACT" -maxdepth 2 -name "*.dmg" | head -n 1 || true)"
            if [ -n "$DMG_FILE" ]; then
              7z x "$DMG_FILE" -o"$TMP_EXTRACT/dmg_out" -y
            fi

            INSTALLER_APP="$(find "$TMP_EXTRACT" -name "Install League of Legends*.app" -type d | head -n 1)"
            if [ -z "$INSTALLER_APP" ]; then
              echo "[lol-darling] Error: Could not locate 'Install League of Legends.app' in archive." >&2
              exit 1
            fi

            rm -rf "$DPREFIX/Applications/Install League of Legends.app"
            cp -a "$INSTALLER_APP" "$DPREFIX/Applications/Install League of Legends.app"
            chmod -R u+rwX "$DPREFIX/Applications/Install League of Legends.app"

            configure_lol

            echo "[lol-darling] Launching macOS Riot Installer inside Darling..."
            darling shell "/Applications/Install League of Legends.app/Contents/MacOS/Install League of Legends"
          fi

          # 3. Apply configuration and launch League via Riot Client Services
          configure_lol

          if [ -d "$DPREFIX/Users/Shared/Riot Games/Riot Client.app" ]; then
            echo "[lol-darling] Launching League of Legends via Riot Client..."
            exec darling shell \
              "/Users/Shared/Riot Games/Riot Client.app/Contents/MacOS/RiotClientServices" \
              --launch-product=league_of_legends \
              --launch-patchline=live \
              "$@"
          else
            echo "[lol-darling] Launching LeagueClient bundle directly..."
            exec darling shell \
              "/Applications/League of Legends.app/Contents/MacOS/LeagueClient" \
              "$@"
          fi
        '';
      };

      desktopItem = pkgs.makeDesktopItem {
        name = "lol-darling";
        desktopName = "League of Legends (Darling)";
        comment = "Play the macOS version of League of Legends on Linux via darling-lol";
        exec = "lol-darling %U";
        icon = "applications-games";
        categories = [ "Game" ];
        terminal = false;
      };

      lol-darling = pkgs.symlinkJoin {
        name = "lol-darling";
        paths = [
          lolLauncherBin
          desktopItem
        ];
      };

    in {
      packages.${system} = {
        inherit darling-lol lol-darling;
        default = lol-darling;
      };

      overlays.default = final: prev: {
        inherit darling-lol lol-darling;
      };

      nixosModules.default = {
        nixpkgs.overlays = [ self.overlays.default ];
        programs.darling = {
          enable = true;
          package = darling-lol;
        };
      };
    };
}
