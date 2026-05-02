#!/bin/bash
echo "Type /help for help."
# Optional system prompt file
SYSTEM_FILE="$HOME/.llm-system-prompt"
EXTRA_ARGS=""
if [ -f "$SYSTEM_FILE" ]; then
    echo "System prompt read successfully from $SYSTEM_FILE"
    EXTRA_ARGS="--sf $SYSTEM_FILE"
fi
exec llm chat $EXTRA_ARGS "$@"