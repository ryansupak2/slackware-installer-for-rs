#!/usr/bin/env python3

import subprocess
import threading
import sys
from rich.live import Live
from rich.markdown import Markdown
from rich.console import Console

console = Console()
output_buffer = ""

def read_output(proc, live):
    global output_buffer
    try:
        for line in iter(proc.stdout.readline, b''):
            line_str = line.decode('utf-8', errors='ignore')
            output_buffer += line_str
            live.update(Markdown(output_buffer))
    except Exception as e:
        pass  # Handle errors gracefully

def main():
    global output_buffer
    # Start llm chat subprocess
    proc = subprocess.Popen(
        ['llm', 'chat'] + sys.argv[1:],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,  # Line buffered
        universal_newlines=False
    )

    with Live(console=console, refresh_per_second=10) as live:
        # Start thread to read output
        thread = threading.Thread(target=read_output, args=(proc, live), daemon=True)
        thread.start()

        try:
            while True:
                # Get user input
                try:
                    user_input = input()
                except EOFError:
                    break
                # Send to subprocess
                proc.stdin.write((user_input + '\n').encode())
                proc.stdin.flush()
                # Exit on quit
                if user_input.strip() in ['quit', 'exit']:
                    break
        except KeyboardInterrupt:
            pass
        finally:
            proc.terminate()
            thread.join(timeout=1)

if __name__ == "__main__":
    main()