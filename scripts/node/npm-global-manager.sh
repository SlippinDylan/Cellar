#!/bin/bash

# Compatibility entrypoint for the modular Node/npm manager.

COMPATIBILITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_ENTRYPOINT="$COMPATIBILITY_DIR/../node-manager/main.sh"

# shellcheck source=../node-manager/main.sh
if ! source "$MANAGER_ENTRYPOINT"; then
    printf 'Failed to load Node manager entrypoint: %s\n' "$MANAGER_ENTRYPOINT" >&2
    if [ "${BASH_SOURCE[0]}" = "$0" ]; then
        exit 1
    fi
    return 1
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
