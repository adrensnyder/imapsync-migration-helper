###################################################################
# Copyright (c) 2023 AdrenSnyder https://github.com/adrensnyder
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

#!/bin/bash

EXCLUDE="INBOX|Sent Items|Deleted Items|Junk Email"
#EXCLUDE="INBOX|Posta inviata/|Posta eliminata/|Posta indesiderata/"

LOGPATH=$1
RED='\033[0;31m'
NC='\033[0m' # No Color

if [[ "X$LOGPATH" == "X" ]]; then
            echo "Enter a valid path for migration logs"
                echo "Ex. /var/log/imapsync/job/data"
                    exit
fi

if [ ! -d $LOGPATH ]; then
                echo "Enter a valid path for migration logs"
                        echo "Ex. /var/log/imapsync/job/data"
                            exit
fi

LIST=$(ls -1 $LOGPATH/*%*)

LIST_NEW=""
LIST_UNIQUE=""
for file in $LIST; do
    EMAIL=`echo $file | awk -F '%' '{ print $1 }'`
    LIST_NEW="$LIST_NEW $EMAIL"
done

LIST_UNIQUE=`echo $LIST_NEW | tr ' ' '\n' | sort -u`

LASTLOGS=()  # inizializza array
echo -e "- ${RED}File list${NC}"

for file in $LIST_UNIQUE; do
    ((COUNT_LIST++))
    LASTLOG=$(ls -1 -r "$LOGPATH/$file%"* | head -n1)
    [[ -n "$LASTLOG" ]] && LASTLOGS+=("$LASTLOG")

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
