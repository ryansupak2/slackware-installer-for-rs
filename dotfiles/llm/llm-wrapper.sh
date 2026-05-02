#!/bin/bash

# Check if python3 and rich are available
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Falling back to plain llm chat."
    exec llm chat "$@"
fi

python3 -c "import rich" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Error: rich library not found. Install with 'pip3 install rich'. Falling back to plain llm chat."
    exec llm chat "$@"
fi

echo "Type !usage for session pricing."
exec python3 /usr/local/bin/llm-chat-formatter.py "$@"