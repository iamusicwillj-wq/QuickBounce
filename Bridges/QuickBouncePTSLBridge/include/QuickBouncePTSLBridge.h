#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *QBPTSLClientRef;

typedef struct QBPTSLResponse {
    int32_t command_id;
    int32_t status;
    int32_t progress;
    int32_t version_major;
    int32_t version_minor;
    int32_t version_revision;
    char *task_id;
    char *body_json;
    char **body_json_chunks;
    int32_t body_json_chunk_count;
    char *error_json;
    char *header_json;
    char *bridge_error;
} QBPTSLResponse;

QBPTSLClientRef qb_ptsl_client_create(const char *address, bool allow_host_launch, char **error_message);
void qb_ptsl_client_destroy(QBPTSLClientRef client);

QBPTSLResponse qb_ptsl_client_send(
    QBPTSLClientRef client,
    int32_t command_id,
    const char *body_json,
    const char *session_id,
    int32_t version_major,
    int32_t version_minor,
    int32_t version_revision,
    const char *header_json
);

void qb_ptsl_client_cancel(QBPTSLClientRef client, bool wait_for_cancel);
void qb_ptsl_response_dispose(QBPTSLResponse *response);
void qb_ptsl_string_dispose(char *value);

const char *qb_ptsl_bridge_sdk_version(void);

#ifdef __cplusplus
}
#endif
