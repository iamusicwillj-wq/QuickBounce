#include "QuickBounceAudioRealtime.h"

#include <stdlib.h>

QBRealtimeMeter *qb_meter_create(void)
{
    QBRealtimeMeter *meter = calloc(1, sizeof(QBRealtimeMeter));
    return meter;
}

void qb_meter_destroy(QBRealtimeMeter *meter)
{
    free(meter);
}

void qb_meter_store(QBRealtimeMeter *meter, float peak_left, float peak_right, float rms_left, float rms_right)
{
    if (meter == NULL) return;
    atomic_store_explicit(&meter->peak_left, peak_left, memory_order_relaxed);
    atomic_store_explicit(&meter->peak_right, peak_right, memory_order_relaxed);
    atomic_store_explicit(&meter->rms_left, rms_left, memory_order_relaxed);
    atomic_store_explicit(&meter->rms_right, rms_right, memory_order_relaxed);
}

void qb_meter_load(const QBRealtimeMeter *meter, float *peak_left, float *peak_right, float *rms_left, float *rms_right)
{
    if (meter == NULL) return;
    if (peak_left != NULL) *peak_left = atomic_load_explicit(&meter->peak_left, memory_order_relaxed);
    if (peak_right != NULL) *peak_right = atomic_load_explicit(&meter->peak_right, memory_order_relaxed);
    if (rms_left != NULL) *rms_left = atomic_load_explicit(&meter->rms_left, memory_order_relaxed);
    if (rms_right != NULL) *rms_right = atomic_load_explicit(&meter->rms_right, memory_order_relaxed);
}
