#!/bin/bash

###################################################################
# Copyright (c) 2026 AdrenSnyder https://github.com/adrensnyder
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# DISCLAIMER:
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
###################################################################

EXCLUDE="INBOX|Sent Items|Deleted Items|Junk Email"
#EXCLUDE="INBOX|Posta inviata/|Posta eliminata/|Posta indesiderata/"

set -u

LOGPATH=${1:-}
RED='\033[0;31m'
NC='\033[0m' # No Color

if [[ -z "$LOGPATH" ]]; then
  echo "Enter a valid path for migration logs"
  echo "Ex. /var/log/imapsync/job/data"
  exit 1
fi

if [[ ! -d "$LOGPATH" ]]; then
  echo "Enter a valid path for migration logs"
  echo "Ex. /var/log/imapsync/job/data"
  exit 1
fi

FILES=()

while IFS= read -r f; do
  base="${f##*/}"

  # skip logrotate output
  [[ "$base" == *.gz ]] && continue
  [[ "$base" =~ \.[0-9]+(\.[0-9]+)*$ ]] && continue

  FILES+=( "$f" )
done < <(find "$LOGPATH" -maxdepth 1 -type f -printf '%p\n' 2>/dev/null)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No log files found in: $LOGPATH"
  exit 0
fi

PREFIXES=()

for f in "${FILES[@]}"; do
  base="${f##*/}"

  if [[ "$base" == *%* ]]; then
    prefix="${base%%\%*}"
  else
    prefix="${base%.log}"
  fi

  PREFIXES+=( "$prefix" )
done

mapfile -t LIST_UNIQUE < <(printf "%s\n" "${PREFIXES[@]}" | sort -u)

LASTLOGS=()

echo -e "- ${RED}File list${NC}"

for file in "${LIST_UNIQUE[@]}"; do
  LASTLOG=$(
    for f in "${FILES[@]}"; do
      base="${f##*/}"

      if [[ "$base" == "$file.log" || "$base" == "$file" || "$base" == "$file%"* ]]; then
        printf '%s %s\n' "$(stat -c %Y "$f")" "$f"
      fi
    done | sort -nr | head -n1 | cut -d' ' -f2-
  )

  [[ -n "$LASTLOG" ]] && LASTLOGS+=( "$LASTLOG" )
  echo "$file -> $LASTLOG"
done

echo ""

for file in "${LASTLOGS[@]}"; do
        echo -e "- ${RED}$file${NC}"
        #grep "does not exist" "$file" |grep -v imapsync | grep -vP "($EXCLUDE)"
        grep "does not exist" "$file" \
          | grep -v imapsync \
          | grep -vP "($EXCLUDE)" \
          | grep -P '\[[^]/]+\]\s+does not exist yet$'
        echo ""
done
