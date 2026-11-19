#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *QBMP3EncoderRef;

QBMP3EncoderRef qb_lame_encoder_create(
    int32_t sample_rate,
    int32_t channel_count,
    int32_t bit_rate_kbps,
    int32_t quality,
    int32_t *status
);

int32_t qb_lame_encoder_encode(
    QBMP3EncoderRef encoder,
    const float *left,
    const float *right,
    int32_t frame_count,
    uint8_t *output,
    int32_t output_capacity
);

int32_t qb_lame_encoder_flush(
    QBMP3EncoderRef encoder,
    uint8_t *output,
    int32_t output_capacity
);

void qb_lame_encoder_destroy(QBMP3EncoderRef encoder);
const char *qb_lame_version(void);

#ifdef __cplusplus
}
#endif
