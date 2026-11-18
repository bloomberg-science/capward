# Cross-Compartment Type Sharing Report: lighttpd

**Libraries analyzed:** lighttpd_merged, openssl_merged, zlib_merged

## Sealing Summary

| Metric | Count |
|--------|-------|
| Total shared types | 40 |
| Sealable (opaque usage) | 33 |
| Needs accessor functions | 6 |
| Address taken (needs subobject bounds) | 1 |
| Cannot seal | 0 |

## Shared Types Detail

### `struct.SCRYPT_PARAMS_st` (owner: openssl_merged)

Total fields: 5

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_name_entry_st` (owner: openssl_merged)

Total fields: 4

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_name_st` (owner: openssl_merged)

Total fields: 5

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.__sFILE` (owner: system)

Total fields: 26

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: _flags, _file
  - Via functions: `open_console`, `read_string_inner`, `file_read`, `file_ctrl`, `RAND_load_file`

### `struct._dirdesc` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.addrinfo` (owner: system)

Total fields: 8

- **lighttpd_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addrlen, ai_addr
  - Via functions: `sock_addr_from_str_hints`, `sock_addr_from_str_numeric`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addr, ai_next
  - Via functions: `BIO_ADDRINFO_free`, `BIO_ADDRINFO_family`, `BIO_ADDRINFO_socktype`, `BIO_ADDRINFO_protocol`, `BIO_ADDRINFO_next`, `BIO_ADDRINFO_address`, `BIO_lookup_ex`

### `struct.asn1_object_st` (owner: openssl_merged)

Total fields: 6

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.asn1_string_st` (owner: openssl_merged)

Total fields: 4

- **lighttpd_merged** [ACCESSOR]
  - Fields accessed: data
  - Via functions: `https_add_ssl_client_entries`

### `struct.bignum_st` (owner: openssl_merged)

Total fields: 5

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_method_st` (owner: openssl_merged)

Total fields: 12

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_st` (owner: openssl_merged)

Total fields: 18

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.const_iovec` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.crypto_ex_data_st` (owner: openssl_merged)

Total fields: 2

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.dirent` (owner: system)

Total fields: 8

- **lighttpd_merged** [ADDR-TAKEN]
  - Fields accessed: d_name
  - Via functions: `mod_dirlisting_subrequest`, `webdav_propfind_dir`, `webdav_delete_dir`, `webdav_copymove_dir`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: d_name
  - Via functions: `OPENSSL_DIR_read`

### `struct.engine_st` (owner: openssl_merged)

Total fields: 28

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_cipher_ctx_st` (owner: openssl_merged)

Total fields: 17

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_cipher_st` (owner: openssl_merged)

Total fields: 34

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_mac_ctx_st` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `EVP_MAC_CTX_free`, `EVP_MAC_CTX_dup`, `EVP_MAC_update`, `evp_mac_final`, `EVP_MAC_CTX_new`, `EVP_MAC_CTX_set_params`, `EVP_MAC_CTX_get0_mac`, `EVP_MAC_init`, `EVP_MAC_CTX_get_mac_size`, `EVP_Q_mac`, `EVP_MAC_CTX_get_block_size`, `EVP_MAC_CTX_get_params`, `EVP_MAC_CTX_gettable_params`, `EVP_MAC_CTX_settable_params`

### `struct.evp_md_ctx_st` (owner: openssl_merged)

Total fields: 9

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_md_st` (owner: openssl_merged)

Total fields: 32

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_pkey_st` (owner: openssl_merged)

Total fields: 19

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_basic_response_st` (owner: openssl_merged)

Total fields: 4

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_response_data_st` (owner: openssl_merged)

Total fields: 5

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_response_st` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `OCSP_response_status`, `OCSP_RESPONSE_print`, `OCSP_response_create`

### `struct.ocsp_single_response_st` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `OCSP_resp_find`, `OCSP_resp_find_status`, `OCSP_SINGLERESP_get0_id`, `OCSP_RESPONSE_print`, `OCSP_basic_add1_status`

### `struct.ossl_init_settings_st` (owner: openssl_merged)

Total fields: 3

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ossl_param_st` (owner: openssl_merged)

Total fields: 5

- **lighttpd_merged** [ACCESSOR]
  - Fields accessed: data_type, data, data_size
  - Via functions: `ssl_tlsext_ticket_key_cb`

### `struct.server` (owner: lighttpd_merged)

Total fields: 32

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr` (owner: system)

Total fields: 3

- **lighttpd_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `server_oneshot_init`, `sock_addr_cache_inet_ntop_copy_buffer`, `network_socket_activation_from_env`, `network_server_init`, `network_host_normalize_addr_str`, `network_srv_socket_init_token`, `network_server_handle_fdevent`, `gw_proc_sockaddr_init`, `gw_spawn_connection`, `http_response_buffer_append_authority`, `http_cgi_headers`, `sock_addr_get_port`, `sock_addr_is_addr_wildcard`, `sock_addr_is_family_eq`, `sock_addr_is_port_eq`, `sock_addr_is_addr_eq`, `sock_addr_is_addr_eq_bits`, `sock_addr_set_port`, `sock_addr_inet_ntop`, `sock_addr_inet_ntop_copy_buffer`, `sock_addr_inet_ntop_append_buffer`, `sock_addr_stringify_append_buffer`, `sock_addr_nameinfo_append_buffer`, `sock_addr_from_str_hints`, `sock_addr_from_str_numeric`, `accesslog_append_remote_addr_masked`, `mod_extforward_set_addr`, `proxy_create_env`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `addr_strings`, `BIO_ADDR_family`, `BIO_ADDR_sockaddr_size`, `BIO_lookup_ex`, `dgram_ctrl`, `BIO_ADDR_make`, `BIO_ADDR_rawaddress`, `BIO_ADDR_new`, `BIO_ADDR_rawport`, `BIO_ADDR_path_string`

### `struct.sockaddr_in` (owner: system)

Total fields: 5

- **lighttpd_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `sock_addr_cache_inet_ntop_copy_buffer`, `http_response_buffer_append_authority`, `sock_addr_get_port`, `sock_addr_is_addr_wildcard`, `sock_addr_is_port_eq`, `sock_addr_is_addr_eq`, `sock_addr_is_addr_eq_bits`, `sock_addr_set_port`, `sock_addr_assign`, `sock_addr_inet_pton`, `sock_addr_inet_ntop`, `sock_addr_inet_ntop_copy_buffer`, `sock_addr_inet_ntop_append_buffer`, `sock_addr_stringify_append_buffer`, `sock_addr_nameinfo_append_buffer`, `sock_addr_from_str_hints`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_in6` (owner: system)

Total fields: 6

- **lighttpd_merged** [ADDR-TAKEN]
  - Fields accessed: sin6_family, sin6_port, sin6_addr
  - Via functions: `sock_addr_cache_inet_ntop_copy_buffer`, `sock_addr_get_port`, `sock_addr_is_addr_wildcard`, `sock_addr_is_port_eq`, `sock_addr_is_addr_eq`, `sock_addr_is_addr_eq_bits`, `sock_addr_set_port`, `sock_addr_assign`, `sock_addr_inet_pton`, `sock_addr_inet_ntop`, `sock_addr_inet_ntop_copy_buffer`, `sock_addr_inet_ntop_append_buffer`, `sock_addr_stringify_append_buffer`, `sock_addr_nameinfo_append_buffer`, `sock_addr_from_str_hints`, `accesslog_append_remote_addr_masked`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin6_family, sin6_port, sin6_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_un` (owner: system)

Total fields: 3

- **lighttpd_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `network_socket_activation_from_env`, `network_server_init`, `network_host_normalize_addr_str`, `network_abstract_socket_parse`, `network_server_handle_fdevent`, `sock_addr_is_addr_eq`, `sock_addr_assign`, `sock_addr_inet_ntop`, `sock_addr_inet_ntop_copy_buffer`, `sock_addr_inet_ntop_append_buffer`, `sock_addr_stringify_append_buffer`, `sock_addr_nameinfo_append_buffer`, `sock_addr_from_str_hints`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `BIO_lookup_ex`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_path_string`

### `struct.ssl_cipher_st` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_get_cipher_by_char`, `bytes_to_cipher_list`, `ssl_create_cipher_list`

### `struct.ssl_cipher_st.65` (owner: openssl_merged)

Total fields: 16

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_conf_ctx_st` (owner: openssl_merged)

Total fields: 14

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_ctx_st` (owner: openssl_merged)

Total fields: 98

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_method_st` (owner: openssl_merged)

Total fields: 29

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_st` (owner: openssl_merged)

Total fields: 130

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st` (owner: openssl_merged)

Total fields: 5

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_ASN1_INTEGER` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509_NAME` (owner: unknown)

Total fields: 0

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.tm` (owner: system)

Total fields: 11

- **lighttpd_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_isdst
  - Via functions: `http_date_if_modified_since`, `http_date_parse_RFC_850`, `http_date_parse_asctime`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday
  - Via functions: `ossl_asn1_time_print_ex`, `ossl_asn1_time_to_tm`, `OPENSSL_gmtime_adj`, `ossl_asn1_time_from_tm`, `ASN1_TIME_to_generalizedtime`, `ASN1_TIME_set_string_X509`, `OPENSSL_gmtime_diff`, `TS_RESP_create_response`

### `struct.x509_cinf_st` (owner: openssl_merged)

Total fields: 11

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_st` (owner: openssl_merged)

Total fields: 27

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_store_ctx_st` (owner: openssl_merged)

Total fields: 36

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_store_st` (owner: openssl_merged)

Total fields: 19

- **lighttpd_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.z_stream_s` (owner: zlib_merged)

Total fields: 14

- **lighttpd_merged** [ADDR-TAKEN]
  - Fields accessed: next_in, avail_in, total_in, next_out, avail_out, total_out, msg, zalloc
  - Via functions: `mod_deflate_stream_init`, `deflate_compress_response`, `deflate_compress_cleanup`, `mod_deflate_compress`
