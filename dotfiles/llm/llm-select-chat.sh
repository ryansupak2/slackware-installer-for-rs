#!/bin/bash

# Get most recent 10 unique conversations
CHATS=$(llm logs --json -n 0 | jq '
  [ .[] | select(.conversation_id) ] | group_by(.conversation_id) | map({
    id: .[0].conversation_id,
    datetime: (map(.datetime_utc) | max),
    subject: .[0].prompt
  } | select(.id != null and .id != "")) | sort_by(.datetime) | reverse | .[0:10]
')

# Build ID array (only valid IDs)
CHAT_IDS=()

# Display menu
echo "Recent Chats:"
count=1
while IFS=$'\t' read -r dt subject id; do
  if [ -n "$id" ]; then
    formatted_date=$(date -d "$dt" +"%a, %d %b %Y - %H:%M:%S")
    echo "$count. $formatted_date > $subject"
    CHAT_IDS+=("$id")
    ((count++))
  fi
done < <(echo "$CHATS" | jq -r '.[] | "\(.datetime)\t\(.subject)\t\(.id)"')
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
      subject: .[0].prompt
    } | select(.id != null and .id != "")) | sort_by(.datetime) | reverse
  ')
  ALL_CHAT_IDS=($(echo "$ALL_CHATS" | jq -r '.[] .id'))
  count=1
  ALL_CHAT_IDS=()
  while IFS=$'\t' read -r dt subject id; do
    if [ -n "$id" ]; then
      formatted_date=$(date -d "$dt" +"%a, %d %b %Y - %H:%M:%S" 2>/dev/null)
      if [ -z "$formatted_date" ]; then formatted_date="Unknown Date"; fi
      echo "$count. $formatted_date > $subject"
      ALL_CHAT_IDS+=("$id")
      ((count++))
    fi
  done < <(echo "$ALL_CHATS" | jq -r '.[] | "\(.datetime)\t\(.subject)\t\(.id)"')
  read -p "Select chat number: " NUM
  if [ "$NUM" -gt 0 ] && [ "$NUM" -le "${#ALL_CHAT_IDS[@]}" ] && [ -n "${ALL_CHAT_IDS[$((NUM-1))]}" ]; then
    CHAT_ID=${ALL_CHAT_IDS[$((NUM-1))]}
  fi
else
  if [ "$SELECTION" -gt 0 ] && [ "$SELECTION" -le "${#CHAT_IDS[@]}" ] && [ -n "${CHAT_IDS[$((SELECTION-1))]}" ]; then
    CHAT_ID=${CHAT_IDS[$((SELECTION-1))]}
  fi
fi

if [ -n "$CHAT_ID" ]; then
  echo "Resuming chat $CHAT_ID"
  llm chat --conversation "$CHAT_ID"
else
  echo "Invalid selection"
fi