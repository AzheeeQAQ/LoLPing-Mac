#!/bin/zsh -f
# Keep this identity across releases: TCC follows the designated requirement.
# The public certificate is in Resources/Signing; its private key stays local.
set -euo pipefail
IDENTITY=1B62AE896C1943FFED89FCBD8098B4FF6C6299A8
REQUIREMENT='=identifier "local.allentu.LoLPing" and certificate root = H"1b62ae896c1943ffed89fcbd8098b4ff6c6299a8"'
VERIFY_ONLY=0
if [[ "${1:-}" == --verify ]]; then VERIFY_ONLY=1; shift; fi
[[ $# == 1 && -d "$1" ]] || { print -u2 'Usage: sign-app.sh [--verify] <LoLPing.app>'; exit 1; }
if [[ "$VERIFY_ONLY" == 0 ]]; then
    if [[ "${LOLPING_ALLOW_ADHOC:-0}" == 1 ]]; then
        print -u2 'Development ad hoc build: permission identity will change; release packaging will reject it.'
        codesign --force --sign - --identifier local.allentu.LoLPing "$1"
        codesign --verify --deep --strict "$1"
        exit 0
    fi
    codesign --force --sign "$IDENTITY" --timestamp=none --identifier local.allentu.LoLPing "$1"
fi
codesign --verify --deep --strict -R "$REQUIREMENT" "$1"
