# Cross-Compartment Type Sharing Report: memcached

**Libraries analyzed:** libevent_merged, memcached_merged, openssl_merged

## Sealing Summary

| Metric | Count |
|--------|-------|
| Total shared types | 19 |
| Sealable (opaque usage) | 18 |
| Needs accessor functions | 1 |
| Address taken (needs subobject bounds) | 0 |
| Cannot seal | 0 |

## Shared Types Detail

### `struct.__sFILE` (owner: system)

Total fields: 26

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **memcached_merged** [ACCESSOR]
  - Fields accessed: _file
  - Via functions: `authfile_load`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: _flags, _file
  - Via functions: `open_console`, `read_string_inner`, `file_read`, `file_ctrl`, `RAND_load_file`

### `struct.addrinfo` (owner: system)

Total fields: 8

- **libevent_merged** [ADDR-TAKEN]
  - Fields accessed: ai_flags, ai_family, ai_socktype, ai_protocol, ai_addrlen, ai_canonname, ai_addr, ai_next
  - Via functions: `bufferevent_socket_connect_hostname`, `bufferevent_connect_getaddrinfo_cb`, `evutil_getaddrinfo`, `test_for_getaddrinfo_hacks`, `evutil_getaddrinfo_common_`, `evutil_new_addrinfo_`, `evutil_freeaddrinfo`, `evutil_addrinfo_append_`, `evutil_adjust_hints_for_addrconfig_`, `bind_socket`, `evdns_getaddrinfo`, `evdns_getaddrinfo_gotresolve`, `evdns_getaddrinfo_timeout_cb`
- **memcached_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addrlen, ai_addr, ai_next
  - Via functions: `server_socket`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addr, ai_next
  - Via functions: `BIO_ADDRINFO_free`, `BIO_ADDRINFO_family`, `BIO_ADDRINFO_socktype`, `BIO_ADDRINFO_protocol`, `BIO_ADDRINFO_next`, `BIO_ADDRINFO_address`, `BIO_lookup_ex`

### `struct.bio_method_st` (owner: openssl_merged)

Total fields: 12

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_st` (owner: openssl_merged)

Total fields: 18

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bufferevent` (owner: libevent_merged)

Total fields: 15

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.conn` (owner: memcached_merged)

Total fields: 50

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.event` (owner: libevent_merged)

Total fields: 8

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.event_base` (owner: libevent_merged)

Total fields: 45

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.event_config` (owner: libevent_merged)

Total fields: 7

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.event_config_entry` (owner: libevent_merged)

Total fields: 2

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.eventop` (owner: libevent_merged)

Total fields: 9

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.fd_set` (owner: openssl_merged)

Total fields: 1

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ossl_init_settings_st` (owner: openssl_merged)

Total fields: 3

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pollfd` (owner: system)

Total fields: 3

- **libevent_merged** [NO-SEAL]
  - Fields accessed: fd, events, revents
  - Via functions: `poll_add`, `poll_del`, `poll_dispatch`
- **memcached_merged** [ACCESSOR]
  - Fields accessed: events, revents
  - Via functions: `lru_crawler_write`

### `struct.pthread` (owner: unknown)

Total fields: 0

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pthread_cond` (owner: unknown)

Total fields: 0

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pthread_mutex` (owner: unknown)

Total fields: 0

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sigaction` (owner: system)

Total fields: 3

- **libevent_merged** [ADDR-TAKEN]
  - Fields accessed: sa_flags, sa_mask
  - Via functions: `evsig_set_handler_`
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr` (owner: system)

Total fields: 3

- **libevent_merged** [ACCESSOR]
  - Fields accessed: sa_len, sa_family
  - Via functions: `bufferevent_socket_connect`, `evutil_socket_connect_`, `evutil_getaddrinfo`, `evutil_new_addrinfo_`, `evutil_found_ifaddr`, `evutil_parse_sockaddr_port`, `evutil_format_sockaddr_port_`, `evutil_sockaddr_cmp`, `evutil_sockaddr_is_loopback_`, `evconnlistener_new_bind`, `evhttp_connection_connect_`, `accept_socket_cb`, `evdns_nameserver_add_impl_`, `evdns_getaddrinfo`
- **memcached_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `process_stats_conns`, `server_socket`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `addr_strings`, `BIO_ADDR_family`, `BIO_ADDR_sockaddr_size`, `BIO_lookup_ex`, `dgram_ctrl`, `BIO_ADDR_make`, `BIO_ADDR_rawaddress`, `BIO_ADDR_new`, `BIO_ADDR_rawport`, `BIO_ADDR_path_string`

### `struct.sockaddr_in` (owner: system)

Total fields: 5

- **libevent_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `evutil_getaddrinfo`, `evutil_getaddrinfo_common_`, `evutil_ersatz_socketpair_`, `evutil_adjust_hints_for_addrconfig_`, `evutil_found_ifaddr`, `evutil_format_sockaddr_port_`, `evutil_sockaddr_cmp`, `evutil_sockaddr_is_loopback_`, `evdns_base_nameserver_add`, `evdns_nameserver_add`, `evdns_getaddrinfo`, `evdns_getaddrinfo_gotresolve`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_in6` (owner: system)

Total fields: 6

- **libevent_merged** [ADDR-TAKEN]
  - Fields accessed: sin6_family, sin6_port, sin6_addr, sin6_scope_id
  - Via functions: `evutil_getaddrinfo`, `evutil_getaddrinfo_common_`, `evutil_adjust_hints_for_addrconfig_`, `evutil_found_ifaddr`, `evutil_parse_sockaddr_port`, `evutil_format_sockaddr_port_`, `evutil_sockaddr_cmp`, `evutil_sockaddr_is_loopback_`, `evdns_getaddrinfo`, `evdns_getaddrinfo_gotresolve`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin6_family, sin6_port, sin6_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_un` (owner: system)

Total fields: 3

- **libevent_merged** [ACCESSOR]
  - Fields accessed: sun_path
  - Via functions: `accept_socket_cb`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `BIO_lookup_ex`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_path_string`

### `struct.ssl_ctx_st` (owner: openssl_merged)

Total fields: 98

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_method_st` (owner: openssl_merged)

Total fields: 29

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_session_st` (owner: unknown)

Total fields: 0

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_cipher_get_evp`, `tls_construct_ctos_early_data`, `SSL_SESSION_set_protocol_version`, `d2i_SSL_SESSION`, `i2d_SSL_SESSION`, `tls_construct_client_hello`, `ssl_get_new_session`, `ssl_get_prev_session`, `ssl_session_cmp`, `SSL_SESSION_get_protocol_version`, `SSL_SESSION_print`

### `struct.ssl_st` (owner: openssl_merged)

Total fields: 130

- **libevent_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509_NAME` (owner: unknown)

Total fields: 0

- **memcached_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.timeval` (owner: system)

Total fields: 2

- **libevent_merged** [ACCESSOR]
  - Fields accessed: tv_sec
  - Via functions: `event_add_nolock_`, `evutil_gettime_monotonic_`, `event_base_gettimeofday_cached`, `event_pending`, `bufferevent_add_event_`, `evutil_tv_to_msec_`, `ev_token_bucket_cfg_new`, `event_base_update_cache_time`, `event_base_init_common_timeout`, `event_base_loop`, `event_process_active_single_queue`, `event_base_once`, `evutil_usleep_`, `evtag_marshal_timeval`, `evtag_unmarshal_timeval`, `accept_socket_cb`, `evdns_strtotimeval`, `evthread_posix_cond_wait`
- **memcached_merged** [ACCESSOR]
  - Fields accessed: tv_usec
  - Via functions: `server_stats`, `do_accept_new_conns`, `main`, `conn_init`, `conn_timeout_thread`, `restart_fixup`
- **openssl_merged** [NO-SEAL]
  - Fields accessed: tv_sec, tv_usec
  - Via functions: `dtls1_ctrl`, `dtls1_handle_timeout`, `dtls1_is_timer_expired`, `ossl_pool_add_nonce_data`, `gcm_ghash_4bit`, `gcm_gmult_4bit`, `BIO_socket_wait`, `dgram_read`, `def_time_cb`

### `struct.tm` (owner: system)

Total fields: 11

- **libevent_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday
  - Via functions: `evutil_date_rfc1123`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday
  - Via functions: `ossl_asn1_time_print_ex`, `ossl_asn1_time_to_tm`, `OPENSSL_gmtime_adj`, `ossl_asn1_time_from_tm`, `ASN1_TIME_to_generalizedtime`, `ASN1_TIME_set_string_X509`, `OPENSSL_gmtime_diff`, `TS_RESP_create_response`
