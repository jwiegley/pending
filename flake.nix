{
  description = "pending - Async pending content placeholders for Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Emacs with package-lint preloaded so `make lint` works inside
        # the dev shell without needing `eask install-deps` first.
        emacsWithDeps = (pkgs.emacsPackagesFor pkgs.emacs-nox).emacsWithPackages
          (epkgs: with epkgs; [
            package-lint
            undercover
          ]);

        src = pkgs.lib.cleanSource ./.;

        runCheck = name: script: pkgs.runCommand "pending-${name}" {
          nativeBuildInputs = [
            emacsWithDeps
            pkgs.eask
            pkgs.texinfo
            pkgs.gnumake
            pkgs.python3
            pkgs.git
            # `scripts/*.sh' use `#!/usr/bin/env bash'.  Without bash
            # in PATH the kernel returns ENOENT for the interpreter,
            # which `make' reports as "No such file or directory" on
            # the script itself.
            pkgs.bash
          ];
        } ''
          cp -r ${src}/. ./work
          chmod -R u+w ./work
          # `scripts/*.sh' use `#!/usr/bin/env bash', but the Linux Nix
          # sandbox has no `/usr/bin/env'.  Rewrite shebangs to absolute
          # store paths so the kernel can exec the scripts directly.
          patchShebangs ./work/scripts
          cd work
          export HOME=$TMPDIR
          ${script}
          touch $out
        '';
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            emacsWithDeps
            pkgs.eask
            pkgs.texinfo
            pkgs.lefthook
            pkgs.git
            pkgs.gnumake
            pkgs.python3
          ];
          shellHook = ''
            echo "pending development shell"
            echo "  emacs    - Emacs with package-lint, undercover"
            echo "  eask     - Elisp build tool"
            echo "  makeinfo - For doc/pending.info"
            echo "  lefthook - Git hooks manager"
            echo ""
            echo "Common targets:"
            echo "  make compile  - byte-compile (warning-free)"
            echo "  make test     - run 77 ERT tests"
            echo "  make lint     - package-lint + checkdoc"
            echo "  make docs     - build doc/pending.info"
            echo "  make coverage - undercover.el coverage report"
          '';
        };

        checks = {
          # Byte-compile with all warnings as errors.
          byte-compile = runCheck "byte-compile" ''
            rm -f *.elc
            emacs --batch -L . \
              --eval "(setq byte-compile-error-on-warn t)" \
              -f batch-byte-compile pending.el pending-test.el
          '';

          # Run the 77 ERT tests.
          tests = runCheck "tests" ''
            emacs --batch -L . \
              -l pending.el -l pending-test.el \
              -f ert-run-tests-batch-and-exit
          '';

          # package-lint, checkdoc, byte-compile -W=error.  Inlined
          # rather than calling `make lint' because `eask lint'
          # tries to refresh package archives over the network,
          # which the Nix sandbox forbids.  `emacsWithDeps' already
          # provides `package-lint', so we invoke it directly.
          lint = runCheck "lint" ''
            emacs --batch -L . \
              --eval "(require 'package-lint)" \
              --eval "(setq package-lint-main-file \"pending.el\")" \
              -f package-lint-batch-and-exit \
              pending.el
            emacs --batch -L . \
              --eval "(require 'checkdoc)" \
              --eval "(checkdoc-file \"pending.el\")"
            rm -f *.elc
            emacs --batch -L . \
              --eval "(setq byte-compile-error-on-warn t)" \
              -f batch-byte-compile pending.el pending-test.el
          '';

          # Reproducible indent-region check.
          format = runCheck "format" ''
            make format-check
          '';

          # makeinfo and check the info file is non-empty.
          docs = runCheck "docs" ''
            make docs
            test -s doc/pending.info
          '';

          # ERT under undercover.el; verifies coverage instrumentation
          # works.  Inlined rather than calling `make coverage` because
          # the latter shells out to `./scripts/coverage.sh`, and the
          # baseline-ratchet logic in that script is for the local
          # workflow, not the reproducible Nix check.
          coverage = runCheck "coverage" ''
            export UNDERCOVER_FORCE=true
            rm -f pending.elc pending-test.elc coverage.lcov
            emacs --batch -L . \
              --eval "(require 'undercover)" \
              --eval "(undercover \"pending.el\" (:report-file \"./coverage.lcov\") (:report-format 'lcov) (:send-report nil))" \
              --eval "(load (expand-file-name \"pending.el\") nil t t)" \
              -l pending-test.el \
              -f ert-run-tests-batch-and-exit
            test -s coverage.lcov
          '';
        };
      }
    );
}
