#!/bin/sh
set -eu
app=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
common="$app/moonlight-common/moonlight-common-c"
output=${1:?pass an output binary path}
${CC:-cc} -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter ${REPLAY_CFLAGS:--O2} \
 -I"$common/enet/include" -I"$common/nanors" -I"$common/nanors/deps/obl" -I"$common/src" \
 "$common/nanors/rs.c" "$common/nanors/deps/obl/oblas_common.c" \
 "$common/nanors/deps/obl/oblas_lite.c" "$common/src/RtpAudioQueue.c" \
 "$common/src/AudioBurstRecovery.c" "$app/tools/diagnostics/replay_audio_guard.c" -o "$output"
