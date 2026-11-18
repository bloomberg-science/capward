# Cross-Compartment Type Sharing Report: nginx

**Libraries analyzed:** nginx_merged, openssl_merged, pcre2_merged, zlib_merged

## Sealing Summary

| Metric | Count |
|--------|-------|
| Total shared types | 50 |
| Sealable (opaque usage) | 41 |
| Needs accessor functions | 9 |
| Address taken (needs subobject bounds) | 0 |
| Cannot seal | 0 |

## Shared Types Detail

### `struct.PBKDF2PARAM_st` (owner: openssl_merged)

Total fields: 4

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_name_st` (owner: openssl_merged)

Total fields: 5

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct._dirdesc` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.addrinfo` (owner: system)

Total fields: 8

- **nginx_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_addrlen, ai_addr, ai_next
  - Via functions: `ngx_inet_resolve_host`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addr, ai_next
  - Via functions: `BIO_ADDRINFO_free`, `BIO_ADDRINFO_family`, `BIO_ADDRINFO_socktype`, `BIO_ADDRINFO_protocol`, `BIO_ADDRINFO_next`, `BIO_ADDRINFO_address`, `BIO_lookup_ex`

### `struct.asn1_string_st` (owner: openssl_merged)

Total fields: 4

- **nginx_merged** [ACCESSOR]
  - Fields accessed: length, data
  - Via functions: `ngx_ssl_ocsp_validate_next`

### `struct.bio_method_st` (owner: openssl_merged)

Total fields: 12

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_st` (owner: openssl_merged)

Total fields: 18

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.crypto_ex_data_st` (owner: openssl_merged)

Total fields: 2

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.dh_st` (owner: openssl_merged)

Total fields: 15

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.dirent` (owner: system)

Total fields: 8

- **nginx_merged** [ADDR-TAKEN]
  - Fields accessed: d_type, d_namlen, d_name
  - Via functions: `ngx_walk_tree`, `ngx_read_dir`, `ngx_http_autoindex_handler`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: d_name
  - Via functions: `OPENSSL_DIR_read`

### `struct.engine_st` (owner: openssl_merged)

Total fields: 28

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_cipher_ctx_st` (owner: openssl_merged)

Total fields: 17

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_cipher_st` (owner: openssl_merged)

Total fields: 34

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_md_ctx_st` (owner: openssl_merged)

Total fields: 9

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_md_st` (owner: openssl_merged)

Total fields: 32

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_pkey_st` (owner: openssl_merged)

Total fields: 19

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.hmac_ctx_st` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `HMAC_Init_ex`, `HMAC_size`, `HMAC_Final`, `HMAC_Update`, `HMAC_CTX_free`, `HMAC_CTX_new`, `HMAC_CTX_copy`, `HMAC_CTX_reset`, `HMAC_CTX_get_md`

### `struct.in6_addr` (owner: system)

Total fields: 1

- **nginx_merged** [NO-SEAL]
  - Fields accessed: __u6_addr
  - Via functions: `ngx_cidr_match`
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **pcre2_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ngx_connection_s` (owner: nginx_merged)

Total fields: 28

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ngx_shm_zone_s` (owner: nginx_merged)

Total fields: 6

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_basic_response_st` (owner: openssl_merged)

Total fields: 4

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_cert_id_st` (owner: openssl_merged)

Total fields: 4

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_one_request_st` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `OCSP_request_add0_id`, `OCSP_REQUEST_print`, `OCSP_onereq_get0_id`

### `struct.ocsp_request_st` (owner: openssl_merged)

Total fields: 2

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_response_data_st` (owner: openssl_merged)

Total fields: 5

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_response_st` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `OCSP_response_status`, `OCSP_RESPONSE_print`, `OCSP_response_create`

### `struct.ossl_init_settings_st` (owner: openssl_merged)

Total fields: 3

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pcre2_memctl` (owner: pcre2_merged)

Total fields: 3

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pcre2_real_code_8` (owner: pcre2_merged)

Total fields: 23

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pcre2_real_compile_context_8` (owner: pcre2_merged)

Total fields: 9

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pcre2_real_general_context_8` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **pcre2_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `pcre2_general_context_create_8`, `pcre2_compile_context_create_8`, `pcre2_match_context_create_8`, `pcre2_convert_context_create_8`, `pcre2_general_context_copy_8`, `pcre2_maketables_8`

### `struct.pcre2_real_match_context_8` (owner: pcre2_merged)

Total fields: 9

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pcre2_real_match_data_8` (owner: pcre2_merged)

Total fields: 14

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr` (owner: system)

Total fields: 3

- **nginx_merged** [ACCESSOR]
  - Fields accessed: sa_len, sa_family
  - Via functions: `ngx_sock_ntop`, `ngx_cidr_match`, `ngx_parse_addr`, `ngx_parse_addr_port`, `ngx_inet_set_port`, `ngx_parse_url`, `ngx_inet_add_addr`, `ngx_cmp_sockaddr`, `ngx_inet_get_port`, `ngx_inet_wildcard`, `ngx_create_listening`, `ngx_set_inherited_sockets`, `ngx_open_listening_sockets`, `ngx_configure_listening_sockets`, `ngx_close_listening_sockets`, `ngx_connection_local_sockaddr`, `ngx_init_cycle`, `ngx_resolver_send_tcp_query`, `ngx_resolver_send_udp_query`, `ngx_resolve_addr`, `ngx_resolve_addr_done`, `ngx_proxy_protocol_write`, `ngx_syslog_send`, `ngx_event_accept`, `ngx_event_recvmsg`, `ngx_event_connect_peer`, `ngx_udp_unix_sendmsg_chain`, `ngx_set_srcaddr_cmsg`, `ngx_get_srcaddr_cmsg`, `ngx_http_add_listen`, `ngx_http_optimize_servers`, `ngx_http_init_connection`, `ngx_http_log_error_handler`, `ngx_http_variable_binary_remote_addr`, `ngx_http_upstream_init_request`, `ngx_http_userid_create_uid`, `ngx_http_access_handler`, `ngx_http_upstream_init_ip_hash_peer`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `addr_strings`, `BIO_ADDR_family`, `BIO_ADDR_sockaddr_size`, `BIO_lookup_ex`, `dgram_ctrl`, `BIO_ADDR_make`, `BIO_ADDR_rawaddress`, `BIO_ADDR_new`, `BIO_ADDR_rawport`, `BIO_ADDR_path_string`

### `struct.sockaddr_in` (owner: system)

Total fields: 5

- **nginx_merged** [ADDR-TAKEN]
  - Fields accessed: sin_len, sin_family, sin_port, sin_addr
  - Via functions: `ngx_sock_ntop`, `ngx_cidr_match`, `ngx_parse_addr`, `ngx_parse_addr_port`, `ngx_inet_set_port`, `ngx_parse_url`, `ngx_inet_add_addr`, `ngx_cmp_sockaddr`, `ngx_inet_get_port`, `ngx_inet_wildcard`, `ngx_connection_local_sockaddr`, `ngx_resolver_export`, `ngx_resolve_addr`, `ngx_proxy_protocol_read`, `ngx_udp_unix_sendmsg_chain`, `ngx_set_srcaddr_cmsg`, `ngx_get_srcaddr_cmsg`, `ngx_http_optimize_servers`, `ngx_http_core_server`, `ngx_http_init_connection`, `ngx_http_variable_binary_remote_addr`, `ngx_http_userid_create_uid`, `ngx_http_access_handler`, `ngx_http_upstream_init_ip_hash_peer`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_in6` (owner: system)

Total fields: 6

- **nginx_merged** [ADDR-TAKEN]
  - Fields accessed: sin6_len, sin6_family, sin6_port, sin6_addr
  - Via functions: `ngx_sock_ntop`, `ngx_cidr_match`, `ngx_parse_addr`, `ngx_parse_addr_port`, `ngx_inet_set_port`, `ngx_parse_url`, `ngx_inet_add_addr`, `ngx_cmp_sockaddr`, `ngx_inet_get_port`, `ngx_inet_wildcard`, `ngx_connection_local_sockaddr`, `ngx_resolver_export`, `ngx_resolve_addr`, `ngx_proxy_protocol_read`, `ngx_udp_unix_sendmsg_chain`, `ngx_set_srcaddr_cmsg`, `ngx_get_srcaddr_cmsg`, `ngx_http_optimize_servers`, `ngx_http_init_connection`, `ngx_http_variable_binary_remote_addr`, `ngx_http_userid_create_uid`, `ngx_http_access_handler`, `ngx_http_upstream_init_ip_hash_peer`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin6_family, sin6_port, sin6_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_un` (owner: system)

Total fields: 3

- **nginx_merged** [ADDR-TAKEN]
  - Fields accessed: sun_len, sun_family, sun_path
  - Via functions: `ngx_sock_ntop`, `ngx_parse_url`, `ngx_cmp_sockaddr`, `ngx_event_recvmsg`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `BIO_lookup_ex`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_path_string`

### `struct.ssl_cipher_st` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_get_cipher_by_char`, `bytes_to_cipher_list`, `ssl_create_cipher_list`

### `struct.ssl_cipher_st.65` (owner: openssl_merged)

Total fields: 16

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_conf_ctx_st` (owner: openssl_merged)

Total fields: 14

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_ctx_st` (owner: openssl_merged)

Total fields: 98

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_method_st` (owner: openssl_merged)

Total fields: 29

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_session_st` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_cipher_get_evp`, `tls_construct_ctos_early_data`, `SSL_SESSION_set_protocol_version`, `d2i_SSL_SESSION`, `i2d_SSL_SESSION`, `tls_construct_client_hello`, `ssl_get_new_session`, `ssl_get_prev_session`, `ssl_session_cmp`, `SSL_SESSION_get_protocol_version`, `SSL_SESSION_print`

### `struct.ssl_session_st.81` (owner: openssl_merged)

Total fields: 33

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_st` (owner: openssl_merged)

Total fields: 130

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st` (owner: openssl_merged)

Total fields: 5

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_OPENSSL_STRING` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509_NAME` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.tm` (owner: system)

Total fields: 11

- **nginx_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_gmtoff
  - Via functions: `ngx_time_update`, `ngx_gmtime`, `ngx_time_sigsafe_update`, `ngx_http_time`, `ngx_http_cookie_time`, `ngx_next_time`, `ngx_localtime`, `ngx_http_autoindex_xml`, `ngx_http_autoindex_html`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday
  - Via functions: `ossl_asn1_time_print_ex`, `ossl_asn1_time_to_tm`, `OPENSSL_gmtime_adj`, `ossl_asn1_time_from_tm`, `ASN1_TIME_to_generalizedtime`, `ASN1_TIME_set_string_X509`, `OPENSSL_gmtime_diff`, `TS_RESP_create_response`

### `struct.ui_method_st` (owner: openssl_merged)

Total fields: 10

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_cinf_st` (owner: openssl_merged)

Total fields: 11

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_lookup_method_st` (owner: unknown)

Total fields: 0

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `X509_LOOKUP_meth_new`, `X509_LOOKUP_meth_free`

### `struct.x509_lookup_st` (owner: openssl_merged)

Total fields: 5

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_st` (owner: openssl_merged)

Total fields: 27

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_store_ctx_st` (owner: openssl_merged)

Total fields: 36

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_store_st` (owner: openssl_merged)

Total fields: 19

- **nginx_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.z_stream_s` (owner: zlib_merged)

Total fields: 14

- **nginx_merged** [ACCESSOR]
  - Fields accessed: avail_in, next_out, avail_out, zalloc, zfree, opaque
  - Via functions: `ngx_http_log_gzip`
