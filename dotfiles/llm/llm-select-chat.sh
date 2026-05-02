#!/bin/bash

# Get most recent 10 unique conversations
CHATS=$(llm logs --json -n 0 | jq '
  [ .[] | select(.conversation_id) ] | group_by(.conversation_id) | map({
    id: .[0].conversation_id,
    datetime: (map(.datetime_utc) | max),
    subject: .[0].prompt
  }) | sort_by(.datetime) | reverse | .[0:9]
')

# Display menu
echo "Recent Chats:"
count=1
echo "$CHATS" | jq -r '.[] | "\(.datetime)|\(.subject)|\(.id)"' | while IFS='|' read dt subject id; do
  formatted_date=$(date -d "$dt" +"%a, %d %b %Y - %H:%M:%S")
  echo "$count. $formatted_date > $subject"
  ((count++))
done
echo ""
echo "0. show all existing chats"

# Get selection
read -p "Select chat to resume (number): " SELECTION

if [ "$SELECTION" = "0" ]; then
  echo "All existing chats:"
  llm logs --json -n 0 | jq -r '.[] | select(.conversation_id) | "\(.conversation_id)|\(.datetime_utc)|\(.prompt)"' | sort -t'|' -k2 -r | awk -F'|' '!seen[$1]++' | while IFS='|' read id dt subject; do
    formatted_date=$(date -d "$dt" +"%a, %d %b %Y - %H:%M:%S")
    echo "$formatted_date > $subject"
  done | nl
  read -p "Select chat number: " NUM
  if [ "$NUM" -gt 0 ]; then
    CHAT_ID=$(llm logs --json -n 0 | jq -r '.[] | select(.conversation_id) | "\(.conversation_id)|\(.datetime_utc)|\(.conversation_name // .prompt | .[0:50])"' | sort -t'|' -k2 -r | awk -F'|' '!seen[$1]++' | sed -n "${NUM}p" | cut -d'|' -f1)
  fi
else
  CHAT_ID=$(echo "$CHATS" | jq -r ".[$((SELECTION-1))].id")
fi

if [ -n "$CHAT_ID" ]; then
  echo "Resuming chat $CHAT_ID"
  llm chat --conversation "$CHAT_ID"
else
  echo "Invalid selection"
fi