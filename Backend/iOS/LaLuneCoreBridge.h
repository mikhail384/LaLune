// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// C API ядра CSQTT/CSQTTR для iOS.
//
// Ядро линкуется статически в основное приложение (libcsqtt_ios_core.a и
// libcsqttr_ios_core.a) и запускается в процессе приложения: без
// NetworkExtension и без системного TUN. Обмен пакетами идёт по UDP на
// 127.0.0.1:52230, дальше их разбирает userspace-стек LaLune.

#ifndef LALUNE_CORE_BRIDGE_H
#define LALUNE_CORE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

typedef void (*csqtt_log_callback)(const char* message);

void csqtt_set_log_callback(csqtt_log_callback callback);
const char* csqtt_get_logs(void);
void csqtt_free_logs(char* ptr);
void csqtt_clear_logs(void);

int csqtt_run(
    const char* peer, const char* vk, const char* password, const char* listen,
    int workers, const char* vk_hash_mode, const char* vk_auth_mode,
    const char* captcha_mode, const char* fingerprint, const char* client_ids,
    const char* obfs, const char* turn_transport, const char* srtp_mode,
    uint64_t generation, const char* salt, const char* turn,
    const char* custom_turn_ips, const char* port, bool validate_vk_hashes,
    const char* tun_uds, bool domain_routing, bool exclude_ru_zones,
    bool template_domains, bool domain_whitelist, const char* direct_domains,
    bool ip_routing, bool ip_whitelist, const char* direct_ips, bool exact_workers
);
int csqtt_stop(void);
int csqtt_status(void);

void csqttr_set_log_callback(csqtt_log_callback callback);
const char* csqttr_get_logs(void);
void csqttr_free_logs(char* ptr);
void csqttr_clear_logs(void);

int csqttr_run_extended(
    const char* peer, const char* vk, const char* password, const char* listen,
    int workers, const char* vk_hash_mode, const char* vk_auth_mode,
    const char* captcha_mode, const char* fingerprint, const char* client_ids,
    const char* obfs, const char* turn_transport, const char* srtp_mode,
    uint64_t generation, const char* salt, const char* turn,
    const char* custom_turn_ips, const char* port, bool validate_vk_hashes,
    const char* tun_uds, bool domain_routing, bool exclude_ru_zones,
    bool template_domains, bool domain_whitelist, const char* direct_domains,
    bool ip_routing, bool ip_whitelist, const char* direct_ips, bool exact_workers
);
int csqttr_stop(void);
int csqttr_status(void);

#endif
