#pragma once

#include <stdatomic.h>

typedef struct QBRealtimeMeter {
    _Atomic float peak_left;
    _Atomic float peak_right;
    _Atomic float rms_left;
    _Atomic float rms_right;
} QBRealtimeMeter;

QBRealtimeMeter *qb_meter_create(void);
void qb_meter_destroy(QBRealtimeMeter *meter);
void qb_meter_store(QBRealtimeMeter *meter, float peak_left, float peak_right, float rms_left, float rms_right);
void qb_meter_load(const QBRealtimeMeter *meter, float *peak_left, float *peak_right, float *rms_left, float *rms_right);
