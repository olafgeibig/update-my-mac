#!/bin/sh
# filepath: /Users/olaf/work/tools/update-my-mac/lib/sudo-askpass-defer.sh
# Description: SUDO_ASKPASS stub for unattended update-my-mac runs.
#              Homebrew calls `sudo -A` when SUDO_ASKPASS is set; this program
#              makes that sudo fail immediately instead of prompting, so a
#              misclassified sudo-requiring upgrade fails fast and is reported
#              rather than hanging the run. Contains no secrets, reads nothing.
# Date: November 11, 2026
# Author: Olaf Geibig

echo "update-my-mac: sudo required - deferred. Run 'update-my-mac --sudo-batch' to install with a single password prompt." >&2
exit 1