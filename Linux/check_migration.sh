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

# --- Build LASTLOGS safely: supports .log, legacy % logs, and fixed-path logs ---
FILES=()

while IFS= read -r f; do
  base="${f##*/}"

  # skip logrotate output
  [[ "$base" != *.log && "$base" != *%* ]] && continue
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

MESSAGESOK_COUNT=0
GOOD_COUNT=0
NOTSTRICT_COUNT=0
NOTFINISHED_COUNT=0
COUNT_LIST=0

LASTLOGS=()
echo ""
echo -e "- ${RED}File list${NC}"

for p in "${LIST_UNIQUE[@]}"; do
  ((COUNT_LIST++))
  # pick latest by modification time
  LASTLOG=$(
    for f in "${FILES[@]}"; do
      base="${f##*/}"
 
      if [[ "$base" == "$p.log" || "$base" == "$p" || "$base" == "$p%"* ]]; then
        printf '%s %s\n' "$(stat -c %Y "$f")" "$f"
      fi
    done | sort -nr | head -n1 | cut -d' ' -f2-
  )
  
  [[ -n "$LASTLOG" ]] && LASTLOGS+=( "$LASTLOG" )
  echo "$p -> $LASTLOG"
done

# --- Stats over last logs ---
for file in "${LASTLOGS[@]}"; do
  MESSAGESOK=$(grep -a "Messages found in host1 not in host2" "$file" | grep ": 0 messages" | wc -l)
  GOOD=$(grep -a "The sync looks good" "$file" | wc -l)
  NOTSTRICT=$(grep -a "The sync is not strict" "$file" | wc -l)
  NOTFINISHED=$(grep -a "The sync is not finished" "$file" | wc -l)

  if [[ "$MESSAGESOK" -gt 0 ]]; then
    ((MESSAGESOK_COUNT++))
  fi

  if [[ "$GOOD" -gt 0 ]]; then
    ((GOOD_COUNT++))
  fi

  if [[ "$NOTFINISHED" -gt 0 ]]; then
    ((NOTFINISHED_COUNT++))
  fi

  if [[ "$NOTSTRICT" -gt 0 && "$GOOD" -eq 0 && "$NOTFINISHED" -eq 0 ]]; then
    ((NOTSTRICT_COUNT++))
  fi
done

ALL_GOOD_NOTFINISHED=0
for file in "${LASTLOGS[@]}"; do
  GOOD_NOTFINISHED=$(grep -a "Exiting with return value" "$file" | wc -l)
  ((ALL_GOOD_NOTFINISHED += GOOD_NOTFINISHED))
done

echo ""
echo -e "- ${RED}General Stats${NC}"
echo "Total emails in check: $COUNT_LIST"
echo "Emails with all messages copied and in sync:"
echo "- Tag 'The sync looks good: $GOOD_COUNT"
echo "- Tag 'Messages found in host1 not in host2 : 0 messages': $MESSAGESOK_COUNT"
echo "Emails copied but with some additional messages in host2 (Only if a unique warning): $NOTSTRICT_COUNT"
echo "Emails with some elements not copied: $NOTFINISHED_COUNT"
echo "Total emails copied, complete or with errors: $ALL_GOOD_NOTFINISHED"

echo ""
echo -e "${RED}- CHECK Status${NC}"

for file in "${LASTLOGS[@]}"; do
  GREP_RESULT=$(grep -a --colour -iTHn -E 'Exiting with return value' "$file" | wc -l)
  if [[ "$GREP_RESULT" -eq 0 ]]; then
    PS_TEST=$(ps auxwf | grep -a imapsync | grep "$(basename "$file")" | wc -l)
    if [[ "$PS_TEST" -gt 0 ]]; then
      echo "--> $file Imapsync process is running"
    else
      echo "--> $file Not completed. Probably terminated cause of an 'Out of memory' error. Try to limit attachments size with --maxsize 150_000_000"
    fi
  else
    GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn -E 'Exiting with return value' "$file"
  fi
done

echo ""
echo -e "${RED}Emails not completed:${NC}"
for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn "The sync is not finished" "$file"
done

echo ""
echo -e "${RED}- CHECK ERROR LOGIN${NC}"
for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn "Error login" "$file"
done

echo ""
echo -e "${RED}- CHECK BAD USER (O365)${NC}"
for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn "bad user" "$file"
done

echo ""
echo -e "${RED}- CHECK EX_OK${NC}"
EXOK_COUNT=0
for file in "${LASTLOGS[@]}"; do
  EXOK=$(grep -a -i "EX_OK" "$file" | wc -l)
  if [[ "$EXOK" -gt 0 ]]; then
    ((EXOK_COUNT++))
  fi
done
echo "$EXOK_COUNT"

echo ""
echo -e "${RED}- CHECK EXIT_ERR_APPEND${NC}"
for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn "EXIT_ERR" "$file"
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn "Maximum number of errors.*reached|reached.*Maximum number of errors" "$file"
done

echo ""
echo -e "${RED}- CHECK skipped${NC}"
for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn -E 'msg.*skipped|skipped.*msg' "$file"
done

echo ""
echo -e "${RED}- CHECK Err${NC}"
for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='fn=01;34:ln=01;32:mt=01;35' grep -a --colour -iTHn -P '^Err ' "$file"
done

echo ""
echo -e "${RED}- CHECK Err (split LOG path/account + extract fields)${NC}"
echo "log_path|account|log_dt|LINE|PRE_ERR|ERRTAG|subject|date|size|flags|msgbox|POST"

for file in "${LASTLOGS[@]}"; do
  GREP_COLORS='' grep -a --color=never -iHn 'Err ' "$file" \
  | while IFS= read -r line; do
      LOG=$(printf '%s' "$line" | cut -d: -f1)
      LINENO=$(printf '%s' "$line" | cut -d: -f2)
      REST=$(printf '%s' "$line" | cut -d: -f3-)

      printf '%s\n' "$REST" \
      | sed -E "s#^(.*)(:?Err[[:space:]]+[0-9]+/[0-9]+:)[[:space:]]*(.*)\$#${LOG}|${LINENO}|\1|\2|\3#" \
      | sed -E '/\|:?Err[[:space:]]+[0-9]+\/[0-9]+:\|/!d' \
      | awk -F'|' '
          function trim(s){ sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

          {
            post = $5
            for (i=6; i<=NF; i++) post = post "|" $i

            log_full = $1
            n = split(log_full, L, /%/)
            log_name = L[1]
            log_dt   = (n >= 2 ? L[2] : "")
            
            log_name = trim(log_name)
            log_dt   = trim(log_dt)
            sub(/\.log$/, "", log_dt)

            p = log_name
            gsub(/\/+$/, "", p)
            last = p
            sub(/^.*\//, "", last)
            path = p
            sub(/\/[^\/]*$/, "", path)
            if (path == p) path = ""

            subject=""; date=""; size=""; flags=""; msgbox=""

            hs = match(post, /Subject:\[([^]]*)\]/, a)
            hd = match(post, /Date:\[([^]]*)\]/,    b)
            hz = match(post, /Size:\[([^]]*)\]/,    c)
            hf = match(post, /Flags:\[([^]]*)\]/,   d)

            # Estrae la parte dopo "- msg " fino a "/" (es: "Sent Messages" da "- msg Sent Messages/970")
            hm = match(post, /- msg[[:space:]]+([^\/]+)\//, e)

            if (hs) subject = a[1]
            if (hd) date    = b[1]
            if (hz) size    = c[1]
            if (hf) flags   = d[1]
            if (hm) msgbox  = e[1]

            gsub(/["'\''"]/, "", subject)
            gsub(/["'\''"]/, "", date)
            gsub(/["'\''"]/, "", size)
            gsub(/["'\''"]/, "", flags)
            gsub(/["'\''"]/, "", msgbox)

            subject = trim(subject)
            date    = trim(date)
            size    = trim(size)
            flags   = trim(flags)
            msgbox  = trim(msgbox)

            print path "|" last "|" log_dt "|" $2 "|" $3 "|" $4 "|" subject "|" date "|" size "|" flags "|" msgbox "|" post
          }
        '
    done
done
