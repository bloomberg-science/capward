# Cross-Compartment Type Sharing Report: wget

**Libraries analyzed:** openssl_merged, wget_merged, zlib_merged

## Sealing Summary

| Metric | Count |
|--------|-------|
| Total shared types | 28 |
| Sealable (opaque usage) | 24 |
| Needs accessor functions | 3 |
| Address taken (needs subobject bounds) | 0 |
| Cannot seal | 1 |

## Shared Types Detail

### `struct.DES_ks` (owner: openssl_merged)

Total fields: 1

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.GENERAL_NAME_st` (owner: openssl_merged)

Total fields: 2

- **wget_merged** [NO-SEAL]
  - Fields accessed: type, d
  - Via functions: `ssl_check_certificate`, `parse_expression`, `parse_bracket_element`

### `struct.MD4state_st` (owner: openssl_merged)

Total fields: 8

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.MD5state_st` (owner: openssl_merged)

Total fields: 8

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_VERIFY_PARAM_st` (owner: openssl_merged)

Total fields: 16

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_name_entry_st` (owner: openssl_merged)

Total fields: 4

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_name_st` (owner: openssl_merged)

Total fields: 5

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_pubkey_st` (owner: openssl_merged)

Total fields: 6

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.__sFILE` (owner: system)

Total fields: 26

- **openssl_merged** [ACCESSOR]
  - Fields accessed: _flags, _file
  - Via functions: `open_console`, `read_string_inner`, `file_read`, `file_ctrl`, `RAND_load_file`
- **wget_merged** [ACCESSOR]
  - Fields accessed: _p, _r, _w, _flags, _file, _bf, _lbfsize, _ub, _offset
  - Via functions: `replace_attr`, `cookie_jar_save`, `yylex`, `ftp_index`, `hsts_store_open`, `hsts_store_save`, `gethttp`, `log_init`, `main`, `bar_set_params`, `fd_read_body`, `warc_write_start_record`, `warc_sha1_stream_with_payload`, `warc_write_response_record`, `fopen_stat`, `wget_read_file`, `determine_screen_width`, `sha1_stream`, `rpl_fflush`, `freading`, `rpl_fseeko`, `error`, `error_tail`, `rpl_getpass`

### `struct.addrinfo` (owner: system)

Total fields: 8

- **openssl_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addr, ai_next
  - Via functions: `BIO_ADDRINFO_free`, `BIO_ADDRINFO_family`, `BIO_ADDRINFO_socktype`, `BIO_ADDRINFO_protocol`, `BIO_ADDRINFO_next`, `BIO_ADDRINFO_address`, `BIO_lookup_ex`
- **wget_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_addr, ai_next
  - Via functions: `lookup_host`

### `struct.asn1_string_st` (owner: openssl_merged)

Total fields: 4

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_method_st` (owner: openssl_merged)

Total fields: 12

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_st` (owner: openssl_merged)

Total fields: 18

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.fd_set` (owner: wget_merged)

Total fields: 1

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.gzFile_s` (owner: zlib_merged)

Total fields: 3

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.gz_state` (owner: zlib_merged)

Total fields: 21

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ossl_init_settings_st` (owner: openssl_merged)

Total fields: 3

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr` (owner: system)

Total fields: 3

- **openssl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `addr_strings`, `BIO_ADDR_family`, `BIO_ADDR_sockaddr_size`, `BIO_lookup_ex`, `dgram_ctrl`, `BIO_ADDR_make`, `BIO_ADDR_rawaddress`, `BIO_ADDR_new`, `BIO_ADDR_rawport`, `BIO_ADDR_path_string`
- **wget_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `bind_local`, `socket_ip_address`, `socket_family`

### `struct.ssl_ctx_st` (owner: openssl_merged)

Total fields: 98

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_method_st` (owner: openssl_merged)

Total fields: 29

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_session_st` (owner: unknown)

Total fields: 0

- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_cipher_get_evp`, `tls_construct_ctos_early_data`, `SSL_SESSION_set_protocol_version`, `d2i_SSL_SESSION`, `i2d_SSL_SESSION`, `tls_construct_client_hello`, `ssl_get_new_session`, `ssl_get_prev_session`, `ssl_session_cmp`, `SSL_SESSION_get_protocol_version`, `SSL_SESSION_print`
- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_session_st.81` (owner: openssl_merged)

Total fields: 33

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_st` (owner: openssl_merged)

Total fields: 130

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st` (owner: openssl_merged)

Total fields: 5

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_GENERAL_NAME` (owner: unknown)

Total fields: 0

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.timeval` (owner: system)

Total fields: 2

- **openssl_merged** [NO-SEAL]
  - Fields accessed: tv_sec, tv_usec
  - Via functions: `dtls1_ctrl`, `dtls1_handle_timeout`, `dtls1_is_timer_expired`, `ossl_pool_add_nonce_data`, `gcm_ghash_4bit`, `gcm_gmult_4bit`, `BIO_socket_wait`, `dgram_read`, `def_time_cb`
- **wget_merged** [ADDR-TAKEN]
  - Fields accessed: tv_usec
  - Via functions: `select_fd`, `ptimer_new`, `ptimer_measure`, `touch`, `rpl_regexec`, `re_search_internal`

### `struct.tm` (owner: system)

Total fields: 11

- **openssl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday
  - Via functions: `ossl_asn1_time_print_ex`, `ossl_asn1_time_to_tm`, `OPENSSL_gmtime_adj`, `ossl_asn1_time_from_tm`, `ASN1_TIME_to_generalizedtime`, `ASN1_TIME_set_string_X509`, `OPENSSL_gmtime_diff`, `TS_RESP_create_response`
- **wget_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_isdst
  - Via functions: `ftp_parse_ls_fp`, `ftp_parse_unix_ls`, `ftp_index`, `gethttp`

### `struct.x509_cinf_st` (owner: openssl_merged)

Total fields: 11

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_lookup_method_st` (owner: unknown)

Total fields: 0

- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `X509_LOOKUP_meth_new`, `X509_LOOKUP_meth_free`
- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_lookup_st` (owner: openssl_merged)

Total fields: 5

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_st` (owner: openssl_merged)

Total fields: 27

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_store_st` (owner: openssl_merged)

Total fields: 19

- **wget_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.z_stream_s` (owner: zlib_merged)

Total fields: 14

- **wget_merged** [ACCESSOR]
  - Fields accessed: avail_in, total_in, next_out, avail_out, zalloc, zfree, opaque
  - Via functions: `fd_read_body`
