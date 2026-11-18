# Cross-Compartment Type Sharing Report: curl

**Libraries analyzed:** curl_merged, openssl_merged, zlib_merged

## Sealing Summary

| Metric | Count |
|--------|-------|
| Total shared types | 54 |
| Sealable (opaque usage) | 42 |
| Needs accessor functions | 11 |
| Address taken (needs subobject bounds) | 0 |
| Cannot seal | 1 |

## Shared Types Detail

### `struct.Cookie` (owner: curl_merged)

Total fields: 16

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.Curl_cfilter` (owner: curl_merged)

Total fields: 6

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.DES_ks` (owner: openssl_merged)

Total fields: 1

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.GENERAL_NAME_st` (owner: openssl_merged)

Total fields: 2

- **curl_merged** [NO-SEAL]
  - Fields accessed: type, d
  - Via functions: `ossl_verifyhost`

### `struct.MD5state_st` (owner: openssl_merged)

Total fields: 8

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.PKCS12_st` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `PKCS12_init_ex`

### `struct.X509_algor_st` (owner: unknown)

Total fields: 0

- **curl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `Curl_ossl_certchain`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `PKCS12_pbe_crypt_ex`, `ossl_ecx_key_op`, `X509_ALGOR_get0`, `ossl_x509_algor_get_md`, `ossl_x509_algor_md_to_mgf1`, `X509_ALGOR_set0`, `ossl_x509_algor_mgf1_decode`, `PKCS5_pbe2_set_iv_ex`, `PKCS5_pbkdf2_set_ex`, `epki2pki_decode`, `rsa_d2i_PKCS8`, `ossl_rsa_key_from_pkcs8`, `sm2_d2i_PKCS8`, `ecx_d2i_PKCS8`, `ec_d2i_PKCS8`, `dsa_d2i_PKCS8`, `dh_d2i_PKCS8`, `ossl_dh_key_from_pkcs8`, `rsa_sig_print`, `rsa_item_verify`, `rsa_sig_info_set`, `ossl_rsa_pss_to_ctx`, `rsa_pss_param_print`, `ASN1_item_verify_ctx`, `PKCS7_dataInit`, `pkcs7_bio_add_digest`, `ossl_cms_ecdsa_dsa_sign`, `ossl_cms_rsa_sign`, `ossl_cms_EncryptedContent_init_bio`, `ossl_cms_RecipientInfo_pwri_crypt`, `ossl_cms_dh_envelope`, `ossl_cms_ecdh_envelope`, `ossl_cms_rsa_envelope`, `ossl_x509_init_sig_info`, `X509_ALGOR_cmp`, `ASN1_sign`, `ASN1_verify`, `PKCS5_pbe2_set_scrypt`, `X509_ALGOR_copy`, `X509_signature_print`, `CMS_RecipientInfo_decrypt`, `CMS_add0_recipient_password`, `ESS_CERT_ID_V2_new_init`, `OCSP_cert_id_new`, `PKCS12_newpass`, `PKCS7_simple_smimecap`, `PKCS7_dataDecode`, `PKCS7_add_signer`, `PKCS7_SIGNER_INFO_set`, `TS_X509_ALGOR_print_bio`, `TS_MSG_IMPRINT_print_bio`, `TS_RESP_create_response`, `int_ts_RESP_verify_token`, `ts_check_imprints`

### `struct.X509_crl_st` (owner: openssl_merged)

Total fields: 18

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_extension_st` (owner: openssl_merged)

Total fields: 3

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_info_st` (owner: openssl_merged)

Total fields: 6

- **curl_merged** [ACCESSOR]
  - Fields accessed: x509, crl
  - Via functions: `Curl_ssl_setup_x509_store`

### `struct.X509_name_entry_st` (owner: openssl_merged)

Total fields: 4

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_name_st` (owner: openssl_merged)

Total fields: 5

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.X509_pubkey_st` (owner: openssl_merged)

Total fields: 6

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.__sFILE` (owner: system)

Total fields: 26

- **curl_merged** [ACCESSOR]
  - Fields accessed: _p, _r, _flags, _file
  - Via functions: `tool_mime_stdin_read`, `get_param_part`, `tool_mime_new_filedata`, `post_per_transfer`, `single_transfer`, `file2memory`, `Curl_get_line`, `Curl_fopen`, `read_part_content`, `addbyter`, `alloc_addbyter`, `storebuffer`, `telnet_do`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: _flags, _file
  - Via functions: `open_console`, `read_string_inner`, `file_read`, `file_ctrl`, `RAND_load_file`

### `struct.addrinfo` (owner: system)

Total fields: 8

- **curl_merged** [ADDR-TAKEN]
  - Fields accessed: ai_family, ai_socktype, ai_addrlen, ai_canonname, ai_addr, ai_next
  - Via functions: `Curl_freeaddrinfo`, `Curl_getaddrinfo_ex`, `Curl_he2ai`, `Curl_unix2addr`, `cf_he_connect`, `baller_start`, `Curl_socket_open`, `Curl_cf_tcp_create`, `cf_socket_open`, `Curl_cf_udp_create`, `Curl_cf_unix_create`, `Curl_printable_address`, `fetch_addr`, `Curl_cache_addr`, `get_localhost`, `Curl_loadhostpairs`, `Curl_doh_is_resolved`, `socks_proxy_cf_connect`, `ftp_state_use_port`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addr, ai_next
  - Via functions: `BIO_ADDRINFO_free`, `BIO_ADDRINFO_family`, `BIO_ADDRINFO_socktype`, `BIO_ADDRINFO_protocol`, `BIO_ADDRINFO_next`, `BIO_ADDRINFO_address`, `BIO_lookup_ex`

### `struct.asn1_object_st` (owner: openssl_merged)

Total fields: 6

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.asn1_string_st` (owner: openssl_merged)

Total fields: 4

- **curl_merged** [ACCESSOR]
  - Fields accessed: length, type, data
  - Via functions: `Curl_ossl_certchain`

### `struct.bignum_st` (owner: openssl_merged)

Total fields: 5

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_method_st` (owner: openssl_merged)

Total fields: 12

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_st` (owner: openssl_merged)

Total fields: 18

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.crypto_ex_data_st` (owner: openssl_merged)

Total fields: 2

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.curl_blob` (owner: unknown)

Total fields: 0

- **curl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `Curl_setblobopt`, `blobcmp`, `Curl_clone_primary_ssl_config`, `Curl_ssl_setup_x509_store`, `cert_stuff`
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.engine_st` (owner: openssl_merged)

Total fields: 28

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_md_ctx_st` (owner: openssl_merged)

Total fields: 9

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_md_st` (owner: openssl_merged)

Total fields: 32

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_pkey_st` (owner: openssl_merged)

Total fields: 19

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.hostent` (owner: system)

Total fields: 5

- **curl_merged** [ACCESSOR]
  - Fields accessed: h_name, h_aliases, h_addrtype, h_addr_list
  - Via functions: `Curl_he2ai`, `Curl_ip2addr`, `Curl_str2addr`
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_basic_response_st` (owner: openssl_merged)

Total fields: 4

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_cert_id_st` (owner: openssl_merged)

Total fields: 4

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_response_data_st` (owner: openssl_merged)

Total fields: 5

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ocsp_response_st` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `OCSP_response_status`, `OCSP_RESPONSE_print`, `OCSP_response_create`

### `struct.ossl_init_settings_st` (owner: openssl_merged)

Total fields: 3

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pthread` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.rsa_st` (owner: openssl_merged)

Total fields: 26

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sha256_ctx` (owner: unknown)

Total fields: 0

- **curl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `my_sha256_init`, `my_sha256_update`, `my_sha256_final`
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr` (owner: system)

Total fields: 3

- **curl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `Curl_addr2string`, `cf_socket_open`, `Curl_if2ip`, `ftp_state_use_port`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `addr_strings`, `BIO_ADDR_family`, `BIO_ADDR_sockaddr_size`, `BIO_lookup_ex`, `dgram_ctrl`, `BIO_ADDR_make`, `BIO_ADDR_rawaddress`, `BIO_ADDR_new`, `BIO_ADDR_rawport`, `BIO_ADDR_path_string`

### `struct.sockaddr_in` (owner: system)

Total fields: 5

- **curl_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `Curl_addr2string`, `cf_socket_open`, `Curl_printable_address`, `Curl_if2ip`, `socks_proxy_cf_connect`, `ftp_state_use_port`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sin_family, sin_port, sin_addr
  - Via functions: `addr_strings`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_rawport`

### `struct.sockaddr_un` (owner: system)

Total fields: 3

- **curl_merged** [ADDR-TAKEN]
  - Fields accessed: sun_path
  - Via functions: `Curl_addr2string`
- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `BIO_lookup_ex`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_path_string`

### `struct.ssl_cipher_st` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_get_cipher_by_char`, `bytes_to_cipher_list`, `ssl_create_cipher_list`

### `struct.ssl_cipher_st.65` (owner: openssl_merged)

Total fields: 16

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_ctx_st` (owner: openssl_merged)

Total fields: 98

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_method_st` (owner: openssl_merged)

Total fields: 29

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_primary_config` (owner: curl_merged)

Total fields: 18

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_session_st` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `ssl_cipher_get_evp`, `tls_construct_ctos_early_data`, `SSL_SESSION_set_protocol_version`, `d2i_SSL_SESSION`, `i2d_SSL_SESSION`, `tls_construct_client_hello`, `ssl_get_new_session`, `ssl_get_prev_session`, `ssl_session_cmp`, `SSL_SESSION_get_protocol_version`, `SSL_SESSION_print`

### `struct.ssl_session_st.81` (owner: openssl_merged)

Total fields: 33

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_st` (owner: openssl_merged)

Total fields: 130

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st` (owner: openssl_merged)

Total fields: 5

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_GENERAL_NAME` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509_EXTENSION` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.stack_st_X509_INFO` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.termios` (owner: system)

Total fields: 7

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.timeval` (owner: system)

Total fields: 2

- **curl_merged** [NO-SEAL]
  - Fields accessed: tv_sec, tv_usec
  - Via functions: `tool_read_cb`, `setfiletime`, `progress_meter`, `tvnow`, `Curl_hsts_save`, `Curl_now`
- **openssl_merged** [NO-SEAL]
  - Fields accessed: tv_sec, tv_usec
  - Via functions: `dtls1_ctrl`, `dtls1_handle_timeout`, `dtls1_is_timer_expired`, `ossl_pool_add_nonce_data`, `gcm_ghash_4bit`, `gcm_gmult_4bit`, `BIO_socket_wait`, `dgram_read`, `def_time_cb`

### `struct.tm` (owner: system)

Total fields: 11

- **curl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday
  - Via functions: `tool_debug_cb`, `Curl_altsvc_save`, `Curl_hsts_save`, `Curl_add_timecondition`, `ftp_state_mdtm_resp`, `file_do`
- **openssl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday
  - Via functions: `ossl_asn1_time_print_ex`, `ossl_asn1_time_to_tm`, `OPENSSL_gmtime_adj`, `ossl_asn1_time_from_tm`, `ASN1_TIME_to_generalizedtime`, `ASN1_TIME_set_string_X509`, `OPENSSL_gmtime_diff`, `TS_RESP_create_response`

### `struct.ui_method_st` (owner: openssl_merged)

Total fields: 10

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ui_st` (owner: openssl_merged)

Total fields: 6

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ui_string_st` (owner: openssl_merged)

Total fields: 7

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_cinf_st` (owner: openssl_merged)

Total fields: 11

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_lookup_method_st` (owner: unknown)

Total fields: 0

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **openssl_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `X509_LOOKUP_meth_new`, `X509_LOOKUP_meth_free`

### `struct.x509_lookup_st` (owner: openssl_merged)

Total fields: 5

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_st` (owner: openssl_merged)

Total fields: 27

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.x509_store_st` (owner: openssl_merged)

Total fields: 19

- **curl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.z_stream_s` (owner: zlib_merged)

Total fields: 14

- **curl_merged** [ACCESSOR]
  - Fields accessed: next_in
  - Via functions: `gzip_unencode_write`, `gzip_close_writer`, `inflate_stream`, `process_trailer`, `deflate_unencode_write`, `deflate_close_writer`
