#!/bin/bash

# Get most recent 10 unique conversations
CHATS=$(llm logs --json -n 0 | jq '
  [ .[] | select(.conversation_id) ] | group_by(.conversation_id) | map({
    id: .[0].conversation_id,
    datetime: (map(.datetime_utc) | max),
    subject: (sort_by(.datetime_utc) | .[0].prompt)
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
  ALL_CHATS=$(llm logs --json -n 0 | jq '
    [ .[] | select(.conversation_id) ] | group_by(.conversation_id) | map({
      id: .[0].conversation_id,
      datetime: (map(.datetime_utc) | max),
      subject: (sort_by(.datetime_utc) | .[0].prompt)
    }) | sort_by(.datetime) | reverse
  ')
  echo "$ALL_CHATS" | jq -r '.[] | "\(.datetime)|\(.subject)|\(.id)"' | while IFS='|' read dt subject id; do
    formatted_date=$(date -d "$dt" +"%a, %d %b %Y - %H:%M:%S")
    echo "$formatted_date > $subject"
  done | nl
  read -p "Select chat number: " NUM
  if [ "$NUM" -gt 0 ]; then
    CHAT_ID=$(echo "$ALL_CHATS" | jq -r ".[$((NUM-1))].id")
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