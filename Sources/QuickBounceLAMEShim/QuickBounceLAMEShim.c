#include "QuickBounceLAMEShim.h"
#include "lame.h"

#include <stddef.h>

QBMP3EncoderRef qb_lame_encoder_create(
    int32_t sample_rate,
    int32_t channel_count,
    int32_t bit_rate_kbps,
    int32_t quality,
    int32_t *status
)
{
    if (status != NULL) {
        *status = -1;
    }
    if (sample_rate <= 0 || (channel_count != 1 && channel_count != 2) ||
        bit_rate_kbps <= 0) {
        return NULL;
    }

    lame_t encoder = lame_init();
    if (encoder == NULL) {
        return NULL;
    }

    int result = 0;
    result |= lame_set_in_samplerate(encoder, sample_rate);
    result |= lame_set_num_channels(encoder, channel_count);
    result |= lame_set_VBR(encoder, vbr_off);
    result |= lame_set_brate(encoder, bit_rate_kbps);
    result |= lame_set_quality(encoder, quality);
    result |= lame_set_bWriteVbrTag(encoder, 0);
    if (channel_count == 1) {
        result |= lame_set_mode(encoder, MONO);
    }
    if (result < 0) {
        lame_close(encoder);
        if (status != NULL) {
            *status = result;
        }
        return NULL;
    }

    result = lame_init_params(encoder);
    if (result < 0) {
        lame_close(encoder);
        if (status != NULL) {
            *status = result;
        }
        return NULL;
    }
    if (status != NULL) {
        *status = 0;
    }
    return (QBMP3EncoderRef)encoder;
}

int32_t qb_lame_encoder_encode(
    QBMP3EncoderRef encoder,
    const float *left,
    const float *right,
    int32_t frame_count,
    uint8_t *output,
    int32_t output_capacity
)
{
    if (encoder == NULL || left == NULL || frame_count < 0 || output == NULL ||
        output_capacity <= 0) {
        return -1;
    }
    lame_t lame = (lame_t)encoder;
    const float *right_channel = right == NULL ? left : right;
    return lame_encode_buffer_ieee_float(
        lame,
        left,
        right_channel,
        frame_count,
        output,
        output_capacity
    );
}

int32_t qb_lame_encoder_flush(
    QBMP3EncoderRef encoder,
    uint8_t *output,
    int32_t output_capacity
)
{
    if (encoder == NULL || output == NULL || output_capacity <= 0) {
        return -1;
    }
    return lame_encode_flush((lame_t)encoder, output, output_capacity);
}

void qb_lame_encoder_destroy(QBMP3EncoderRef encoder)
{
    if (encoder != NULL) {
        lame_close((lame_t)encoder);
    }
}

const char *qb_lame_version(void)
{
    return get_lame_version();
}
