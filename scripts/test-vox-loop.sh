#!/bin/bash
# test-vox-loop.sh — VOX transcription test loop
#
# Runs voxd --file against newyorkgroove.wav N times and reports
# timing + accuracy stats versus ground truth.

WAV="${1:-/tmp/newyorkgroove.wav}"
PASSES="${2:-5}"
VOXD="/usr/local/bin/voxd"

GROUND_TRUTH="here i am again in the city with a fistful of dollars and baby youd better believe im back back in the new york groove"

if [ ! -f "$WAV" ]; then
    echo "ERROR: WAV file not found: $WAV"
    exit 1
fi

if [ ! -x "$VOXD" ]; then
    echo "ERROR: voxd not found at $VOXD"
    exit 1
fi

echo "=========================================="
echo "VOXD TEST LOOP — $PASSES passes"
echo "WAV: $WAV ($(soxi -D "$WAV" 2>/dev/null || echo '?'))s"
echo "Ground truth: $GROUND_TRUTH"
echo "=========================================="

total_real=0
total_user=0
passes_ok=0

for i in $(seq 1 "$PASSES"); do
    echo ""
    echo "--- Pass $i/$PASSES ---"

    START=$(date +%s%N)

    OUTPUT=$($VOXD --file "$WAV" 2>&1)

    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    ELAPSED_S=$(echo "scale=2; $ELAPSED_MS / 1000" | bc 2>/dev/null || echo "$ELAPSED_MS ms")

    # Extract the final segment text
    SEGMENT=$(echo "$OUTPUT" | grep "final segment" -B1 | head -1 | sed 's/^.*[0-9]: //')

    echo "  Time: ${ELAPSED_S}s"
    echo "  Output: $SEGMENT"

    # Compare with ground truth (simple word overlap)
    if [ -n "$SEGMENT" ]; then
        # Count matching words
        MATCH=0
        TOTAL_GT=0
        for word in $GROUND_TRUTH; do
            TOTAL_GT=$((TOTAL_GT + 1))
            case " $SEGMENT " in
                *" $word "*) MATCH=$((MATCH + 1)) ;;
            esac
        done
        TOTAL_OUT=$(echo "$SEGMENT" | wc -w)
        echo "  Accuracy: ${MATCH}/${TOTAL_GT} ground-truth words matched (${TOTAL_OUT} output words)"
        passes_ok=$((passes_ok + 1))
    else
        echo "  WARNING: no output"
    fi
done

echo ""
echo "=========================================="
echo "All $PASSES passes complete ($passes_ok produced output)"
echo "=========================================="
