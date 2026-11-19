#include "QuickBouncePTSLBridge.h"

#include "CppPTSLClient.h"
#include "CppPTSLRequest.h"
#include "CppPTSLResponse.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <vector>

namespace {

struct BridgeClient {
    std::unique_ptr<PTSLC_CPP::CppPTSLClient> client;
};

char *copy_string(const std::string &value)
{
    auto *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (result == nullptr) {
        return nullptr;
    }
    std::memcpy(result, value.data(), value.size());
    result[value.size()] = '\0';
    return result;
}

char **copy_strings(const std::vector<std::string> &values)
{
    if (values.empty()) {
        return nullptr;
    }

    auto **result = static_cast<char **>(std::calloc(values.size(), sizeof(char *)));
    if (result == nullptr) {
        return nullptr;
    }

    for (std::size_t index = 0; index < values.size(); ++index) {
        result[index] = copy_string(values[index]);
        if (result[index] == nullptr) {
            for (std::size_t allocated = 0; allocated < index; ++allocated) {
                std::free(result[allocated]);
            }
            std::free(result);
            return nullptr;
        }
    }
    return result;
}

const char *safe_string(const char *value)
{
    return value == nullptr ? "" : value;
}

QBPTSLResponse empty_response(int32_t command_id)
{
    QBPTSLResponse response{};
    response.command_id = command_id;
    response.status = -1;
    return response;
}

} // namespace

QBPTSLClientRef qb_ptsl_client_create(const char *address, bool allow_host_launch, char **error_message)
{
    if (error_message != nullptr) {
        *error_message = nullptr;
    }

    try {
        PTSLC_CPP::ClientConfig config{
            safe_string(address)[0] == '\0' ? "localhost:31416" : safe_string(address),
            PTSLC_CPP::Mode::Mode_ProTools,
            allow_host_launch ? PTSLC_CPP::SkipHostLaunch::SHLaunch_No : PTSLC_CPP::SkipHostLaunch::SHLaunch_Yes
        };

        auto bridge = std::make_unique<BridgeClient>();
        bridge->client = std::make_unique<PTSLC_CPP::CppPTSLClient>(config);
        return bridge.release();
    } catch (const std::exception &error) {
        if (error_message != nullptr) {
            *error_message = copy_string(error.what());
        }
    } catch (...) {
        if (error_message != nullptr) {
            *error_message = copy_string("Unknown exception while creating PTSL client");
        }
    }
    return nullptr;
}

void qb_ptsl_client_destroy(QBPTSLClientRef client)
{
    delete static_cast<BridgeClient *>(client);
}

QBPTSLResponse qb_ptsl_client_send(
    QBPTSLClientRef client,
    int32_t command_id,
    const char *body_json,
    const char *session_id,
    int32_t version_major,
    int32_t version_minor,
    int32_t version_revision,
    const char *header_json
)
{
    QBPTSLResponse result = empty_response(command_id);
    auto *bridge = static_cast<BridgeClient *>(client);
    if (bridge == nullptr || bridge->client == nullptr) {
        result.bridge_error = copy_string("PTSL client is unavailable");
        return result;
    }

    try {
        PTSLC_CPP::CppPTSLRequest request(
            static_cast<PTSLC_CPP::CommandId>(command_id),
            safe_string(body_json)
        );
        request.SetSessionId(safe_string(session_id));
        request.SetVersion(version_major);
        request.SetVersionMinor(version_minor);
        request.SetVersionRevision(version_revision);
        request.SetVersionedRequestHeaderJson(safe_string(header_json));

        // Commands such as GetTrackList stream their payload in intermediate
        // responses and return an empty body in the final future. Preserve all
        // callback bodies so Swift can merge the stream instead of seeing an
        // apparently empty Session.
        std::vector<std::string> bodyChunks;
        auto response = bridge->client->SendRequest(
            std::move(request),
            [&](const PTSLC_CPP::CppPTSLResponse &streamedResponse) {
                const auto body = streamedResponse.GetResponseBodyJson();
                if (!body.empty()) {
                    bodyChunks.push_back(body);
                }
            }
        ).get();
        const auto finalBody = response.GetResponseBodyJson();
        if (!finalBody.empty() && (bodyChunks.empty() || bodyChunks.back() != finalBody)) {
            bodyChunks.push_back(finalBody);
        }
        result.command_id = static_cast<int32_t>(response.GetCommandId());
        result.status = static_cast<int32_t>(response.GetStatus());
        result.progress = response.GetProgress();
        result.version_major = response.GetVersion();
        result.version_minor = response.GetVersionMinor();
        result.version_revision = response.GetVersionRevision();
        result.task_id = copy_string(response.GetTaskId());
        result.body_json = copy_string(finalBody);
        result.body_json_chunk_count = static_cast<int32_t>(bodyChunks.size());
        result.body_json_chunks = copy_strings(bodyChunks);
        if (!bodyChunks.empty() && result.body_json_chunks == nullptr) {
            result.bridge_error = copy_string("Unable to allocate PTSL response body chunks");
        }
        result.error_json = copy_string(response.GetResponseErrorJson());
        result.header_json = copy_string(response.GetVersionedResponseHeaderJson());
    } catch (const std::exception &error) {
        result.bridge_error = copy_string(error.what());
    } catch (...) {
        result.bridge_error = copy_string("Unknown exception while sending PTSL request");
    }
    return result;
}

void qb_ptsl_client_cancel(QBPTSLClientRef client, bool wait_for_cancel)
{
    auto *bridge = static_cast<BridgeClient *>(client);
    if (bridge != nullptr && bridge->client != nullptr) {
        bridge->client->CancelRequests(wait_for_cancel);
    }
}

void qb_ptsl_response_dispose(QBPTSLResponse *response)
{
    if (response == nullptr) {
        return;
    }
    qb_ptsl_string_dispose(response->task_id);
    qb_ptsl_string_dispose(response->body_json);
    if (response->body_json_chunks != nullptr) {
        for (int32_t index = 0; index < response->body_json_chunk_count; ++index) {
            qb_ptsl_string_dispose(response->body_json_chunks[index]);
        }
        std::free(response->body_json_chunks);
    }
    qb_ptsl_string_dispose(response->error_json);
    qb_ptsl_string_dispose(response->header_json);
    qb_ptsl_string_dispose(response->bridge_error);
    *response = empty_response(response->command_id);
}

void qb_ptsl_string_dispose(char *value)
{
    std::free(value);
}

const char *qb_ptsl_bridge_sdk_version(void)
{
    // PTSL_Versions.h is a private SDK build header and is intentionally not
    // installed in Avid's public framework Headers directory. Keep this value
    // pinned to the vendored 2026.04 framework beside this bridge.
    return "2026.4.0";
}
