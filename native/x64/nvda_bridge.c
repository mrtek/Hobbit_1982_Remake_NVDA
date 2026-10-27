/*
 * nvda_bridge.c - Headless Native Bridge between Godot Engine and NVDA Screen Reader
 * Part of "The Hobbit (1982 Remake)" Accessibility System
 *
 * Communicates with Godot via standard input/output (stdin/stdout) using JSON-lines.
 * Calls NVDA Controller Client API (64-bit RPC).
 */

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "nvdaController.h"

#define BUFFER_SIZE 65536

static HANDLE hStdin = NULL;
static HANDLE hStdout = NULL;

static void send_response(const char* json_str) {
    if (!hStdout) return;
    DWORD len = (DWORD)strlen(json_str);
    DWORD written = 0;
    WriteFile(hStdout, json_str, len, &written, NULL);
    WriteFile(hStdout, "\n", 1, &written, NULL);
    FlushFileBuffers(hStdout);
}

// Simple JSON string value extractor for flat JSON objects
static bool get_json_string_field(const char* json, const char* key, char* out_buf, size_t max_out) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return false;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':' || *p == '\t') p++;
    if (*p != '\"') return false;
    p++; // skip opening quote
    size_t idx = 0;
    while (*p && *p != '\"' && idx + 1 < max_out) {
        if (*p == '\\' && *(p + 1)) {
            p++;
            switch (*p) {
                case 'n': out_buf[idx++] = '\n'; break;
                case 'r': out_buf[idx++] = '\r'; break;
                case 't': out_buf[idx++] = '\t'; break;
                case '\"': out_buf[idx++] = '\"'; break;
                case '\\': out_buf[idx++] = '\\'; break;
                default: out_buf[idx++] = *p; break;
            }
            p++;
        } else {
            out_buf[idx++] = *p++;
        }
    }
    out_buf[idx] = '\0';
    return true;
}

static bool get_json_bool_field(const char* json, const char* key, bool default_val) {
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char* p = strstr(json, pattern);
    if (!p) return default_val;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':' || *p == '\t') p++;
    if (strncmp(p, "true", 4) == 0) return true;
    if (strncmp(p, "false", 5) == 0) return false;
    return default_val;
}

int main(int argc, char* argv[]) {
    // Set console code page to UTF-8
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);

    hStdin = GetStdHandle(STD_INPUT_HANDLE);
    hStdout = GetStdHandle(STD_OUTPUT_HANDLE);

    if (hStdin == INVALID_HANDLE_VALUE || hStdout == INVALID_HANDLE_VALUE) {
        return 1;
    }

    // Send ready handshake
    send_response("{\"status\":\"ready\",\"version\":\"3.0\"}");

    char line_buffer[BUFFER_SIZE];
    DWORD bytes_read = 0;
    size_t line_pos = 0;

    char ch;
    while (ReadFile(hStdin, &ch, 1, &bytes_read, NULL) && bytes_read > 0) {
        if (ch == '\r') continue;
        if (ch == '\n') {
            line_buffer[line_pos] = '\0';
            if (line_pos > 0) {
                char cmd[64] = {0};
                if (get_json_string_field(line_buffer, "cmd", cmd, sizeof(cmd))) {
                    if (strcmp(cmd, "test") == 0) {
                        long res = nvdaController_testIfRunning();
                        char resp[128];
                        snprintf(resp, sizeof(resp), "{\"active\":%s,\"code\":%ld}", 
                            (res == 0) ? "true" : "false", res);
                        send_response(resp);
                    }
                    else if (strcmp(cmd, "speak") == 0) {
                        bool interrupt = get_json_bool_field(line_buffer, "interrupt", false);
                        char text_utf8[BUFFER_SIZE] = {0};
                        if (get_json_string_field(line_buffer, "text", text_utf8, sizeof(text_utf8))) {
                            if (interrupt) {
                                nvdaController_cancelSpeech();
                            }
                            // Convert UTF-8 to wchar_t
                            int wlen = MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, NULL, 0);
                            if (wlen > 0) {
                                wchar_t* wbuf = (wchar_t*)malloc(wlen * sizeof(wchar_t));
                                if (wbuf) {
                                    MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, wbuf, wlen);
                                    long res = nvdaController_speakText(wbuf);
                                    free(wbuf);
                                    char resp[64];
                                    snprintf(resp, sizeof(resp), "{\"ok\":%s,\"code\":%ld}", (res == 0) ? "true" : "false", res);
                                    send_response(resp);
                                } else {
                                    send_response("{\"ok\":false,\"error\":\"out_of_memory\"}");
                                }
                            } else {
                                send_response("{\"ok\":true,\"code\":0}");
                            }
                        } else {
                            send_response("{\"ok\":false,\"error\":\"missing_text\"}");
                        }
                    }
                    else if (strcmp(cmd, "cancel") == 0) {
                        long res = nvdaController_cancelSpeech();
                        char resp[64];
                        snprintf(resp, sizeof(resp), "{\"ok\":%s,\"code\":%ld}", (res == 0) ? "true" : "false", res);
                        send_response(resp);
                    }
                    else if (strcmp(cmd, "braille") == 0) {
                        char text_utf8[BUFFER_SIZE] = {0};
                        if (get_json_string_field(line_buffer, "text", text_utf8, sizeof(text_utf8))) {
                            int wlen = MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, NULL, 0);
                            if (wlen > 0) {
                                wchar_t* wbuf = (wchar_t*)malloc(wlen * sizeof(wchar_t));
                                if (wbuf) {
                                    MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, wbuf, wlen);
                                    long res = nvdaController_brailleMessage(wbuf);
                                    free(wbuf);
                                    char resp[64];
                                    snprintf(resp, sizeof(resp), "{\"ok\":%s,\"code\":%ld}", (res == 0) ? "true" : "false", res);
                                    send_response(resp);
                                }
                            }
                        }
                    }
                    else if (strcmp(cmd, "quit") == 0) {
                        send_response("{\"status\":\"bye\"}");
                        break;
                    }
                    else {
                        send_response("{\"ok\":false,\"error\":\"unknown_command\"}");
                    }
                }
            }
            line_pos = 0;
        } else {
            if (line_pos + 1 < sizeof(line_buffer)) {
                line_buffer[line_pos++] = ch;
            }
        }
    }

    return 0;
}
