{
  description = "dialect — a Ruby GTK4 port";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Shared libraries every ruby-gnome extension links against.
        gtkStack = with pkgs; [
          glib
          gobject-introspection
          cairo
          pango
          gdk-pixbuf
          graphene
          atk
          gtk4
          libadwaita
          harfbuzz
          librsvg
        ]
        # The Ruby `pkg-config` gem resolves `Requires.private` transitively and
        # hard-fails if any .pc in the chain is missing, so gtk4's whole private
        # closure has to be on PKG_CONFIG_PATH, not just its public deps.
        ++ (with pkgs; [
          fontconfig
          freetype
          libepoxy
          libpng
          libxkbcommon
          pcre2
          util-linux
          wayland
          zlib
          fribidi
          libdatrie
          libthai
          libselinux
          libsepol
          expat
          brotli
          bzip2
          graphite2
          icu
          libffi
          libxml2
          lerc
          libdeflate
          xz
          zstd
        ])
        # Un-prefixed names: the `xorg.*` package set is deprecated.
        ++ (with pkgs; [
          libx11
          libxau
          libxcursor
          libxdmcp
          libxext
          libxfixes
          libxi
          libxinerama
          libxrandr
          libxrender
          libxcb
          xorgproto
        ]);

        # ruby-gnome gems build C extensions with extconf.rb + the pkg-config
        # gem; nixpkgs only ships gemConfig entries for the GTK3-era subset, so
        # the GTK4 gems get their build inputs declared here.
        rubyGnomeGem = _attrs: {
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = gtkStack;
        };

        gemConfig = pkgs.defaultGemConfig // {
          gdk4 = rubyGnomeGem;
          gsk4 = rubyGnomeGem;
          gtk4 = rubyGnomeGem;
          graphene1 = rubyGnomeGem;
          adwaita = rubyGnomeGem;
          rsvg2 = rubyGnomeGem;
        };

        # `makeSearchPath` would take each package's *first* output, and glib's
        # first output is `bin`, which carries no typelibs — hence the explicit
        # `.out`. at-spi2-core is here for the Atk typelib.
        typelibPath = pkgs.lib.makeSearchPath "lib/girepository-1.0"
          (map (drv: drv.out or drv) (gtkStack ++ [ pkgs.at-spi2-core ]));

        # nix/ and not the repo root: the root Gemfile is kettle-jem's
        # development bundle — rubocop, rspec, yard, the kettle-dev stack — and
        # must not end up in a packaged app's runtime closure. nix/Gemfile holds
        # the gemspec's runtime dependencies only.
        gems = pkgs.bundlerEnv {
          name = "dialect-gems";
          ruby = pkgs.ruby_3_4;
          inherit gemConfig;
          gemdir = ./nix;
        };

        # The launcher is whatever the gemspec installs into exe/. Reading the
        # directory keeps this flake generic: no name to keep in step by hand.
        launcher = builtins.head (builtins.attrNames (builtins.readDir ./exe));

        # Optional directories: a port that has not grown translations or data
        # assets yet simply has none.
        optionalDirs = builtins.filter (d: builtins.pathExists (./. + "/${d}")) [
          "data"
          "po"
        ];
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "dialect";
          version = "0.1.0";
          src = ./.;

          # Deliberately no wrapGAppsHook4: glib's setup hook relocates
          # share/glib-2.0/schemas during fixup, after wrapGAppsHook4 has
          # computed its wrapper arguments, so a schema would end up somewhere
          # the wrapper never looks. The wrapper below is built by hand and
          # points at both the pre- and post-move paths.
          nativeBuildInputs = [ pkgs.makeWrapper ];
          buildInputs = [ gems ] ++ gtkStack;

          dontBuild = true;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/share/dialect
            cp -r lib $out/share/dialect/
            for d in ${pkgs.lib.escapeShellArgs optionalDirs}; do
              cp -r "$d" $out/share/dialect/
            done
            # exe/ sits next to lib/ so the launcher's `require "dialect"`
            # resolves against the copied tree.
            install -Dm755 exe/${launcher} $out/share/dialect/exe/${launcher}

            # Compile any GSettings schema the port ships.
            if [ -d data/schemas ]; then
              mkdir -p $out/share/glib-2.0/schemas
              cp data/schemas/*.gschema.xml $out/share/glib-2.0/schemas/
              ${pkgs.glib.dev}/bin/glib-compile-schemas $out/share/glib-2.0/schemas
            fi

            # -rbundler/setup puts the bundled gems on the load path, and
            # GI_TYPELIB_PATH keeps GObject-Introspection from re-registering
            # types the cairo gem's C extension has already registered.
            makeWrapper ${gems.wrappedRuby}/bin/ruby $out/bin/${launcher} \
              --add-flags "-rbundler/setup" \
              --add-flags "-I$out/share/dialect/lib" \
              --add-flags "$out/share/dialect/exe/${launcher}" \
              --set GI_TYPELIB_PATH "${typelibPath}" \
              --prefix XDG_DATA_DIRS : "$out/share" \
              --prefix XDG_DATA_DIRS : "$out/share/gsettings-schemas/dialect-0.1.0" \
              --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
              --prefix XDG_DATA_DIRS : "${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}" \
              --prefix XDG_DATA_DIRS : "${pkgs.adwaita-icon-theme}/share"

            runHook postInstall
          '';

          meta = {
            description = "A Ruby GTK4 / Libadwaita port of dialect";
            mainProgram = launcher;
            platforms = pkgs.lib.platforms.linux;
          };
        };

        apps.default = utils.lib.mkApp { drv = self.packages.${system}.default; };

        devShells.default = pkgs.mkShell {
          name = "dialect-devshell";

          packages = [
            gems
            gems.wrappedRuby
            pkgs.bundler
            pkgs.bundix
            pkgs.pkg-config
            pkgs.glib.dev
            pkgs.gettext
            pkgs.gsettings-desktop-schemas
            pkgs.adwaita-icon-theme
          ] ++ gtkStack;

          # Icons, GSettings schemas and the GTK portal all resolve through
          # XDG_DATA_DIRS; without these the window opens with blank icons.
          shellHook = ''
            export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}:${pkgs.adwaita-icon-theme}/share:$XDG_DATA_DIRS"
            export GI_TYPELIB_PATH="${typelibPath}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
            [ -d data/schemas ] && export GSETTINGS_SCHEMA_DIR="$PWD/data/schemas"
            unset BUNDLE_GEMFILE BUNDLE_FROZEN
            echo "dialect devshell — ruby $(ruby -e 'print RUBY_VERSION')"
          '';
        };
      });
}
