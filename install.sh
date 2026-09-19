#!/bin/sh
set -eu
printf '%s\n' 'This checkout is code-server lite; the upstream installer is disabled.'
printf '%s\n' 'Install Node.js 24 and Git, set PASSWORD (12+ characters), then run:'
printf '%s\n' '  node lite/server.mjs --root /path/to/project'
printf '%s\n' 'See README.md for mandatory HTTPS reverse-proxy settings for remote access.'
if [ "${1-}" = "--help" ]; then exit 0; fi
exit 1
