# Cross-Compartment Type Sharing Report: redis

**Libraries analyzed:** openssl_merged, redis_merged

## Sealing Summary

| Metric | Count |
|--------|-------|
| Total shared types | 13 |
| Sealable (opaque usage) | 12 |
| Needs accessor functions | 1 |
| Address taken (needs subobject bounds) | 0 |
| Cannot seal | 0 |

## Shared Types Detail

### `struct.ACLLogEntry` (owner: redis_merged)

Total fields: 7

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.__sFILE` (owner: system)

Total fields: 26

- **openssl_merged** [ACCESSOR]
  - Fields accessed: _flags, _file
  - Via functions: `open_console`, `read_string_inner`, `file_read`, `file_ctrl`, `RAND_load_file`
- **redis_merged** [ACCESSOR]
  - Fields accessed: _r, _flags, _file
  - Via functions: `redisAsciiArt`, `rdbSave`, `rdbLoad`, `rewriteConfigReadOldFile`, `aofLoadManifestFromFile`, `rewriteAppendOnlyFile`, `loadSingleAppendOnlyFile`, `clusterLoadConfig`, `rioFileWrite`, `redis_check_rdb`, `processAnnotations`, `checkSingleAof`, `fileIsRDB`, `fileIsManifest`, `luaL_loadfile`, `getF`

### `struct.addrinfo` (owner: system)

Total fields: 8

- **openssl_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addr, ai_next
  - Via functions: `BIO_ADDRINFO_free`, `BIO_ADDRINFO_family`, `BIO_ADDRINFO_socktype`, `BIO_ADDRINFO_protocol`, `BIO_ADDRINFO_next`, `BIO_ADDRINFO_address`, `BIO_lookup_ex`
- **redis_merged** [ACCESSOR]
  - Fields accessed: ai_family, ai_socktype, ai_protocol, ai_addrlen, ai_addr, ai_next
  - Via functions: `anetResolve`, `anetTcpGenericConnect`, `_anetTcpServer`, `_redisContextConnectTcp`

### `struct.bio_method_st` (owner: openssl_merged)

Total fields: 12

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.bio_st` (owner: openssl_merged)

Total fields: 18

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.evp_pkey_st` (owner: openssl_merged)

Total fields: 19

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.iovec` (owner: unknown)

Total fields: 0

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **redis_merged** [ACCESSOR]
  - Fields accessed: 0
  - Via functions: `connTLSWritev`

### `struct.ossl_decoder_ctx_st` (owner: openssl_merged)

Total fields: 8

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ossl_init_settings_st` (owner: openssl_merged)

Total fields: 3

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ossl_lib_ctx_st` (owner: openssl_merged)

Total fields: 10

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.pthread` (owner: unknown)

Total fields: 0

- **openssl_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr` (owner: system)

Total fields: 3

- **openssl_merged** [ACCESSOR]
  - Fields accessed: sa_family
  - Via functions: `addr_strings`, `BIO_ADDR_family`, `BIO_ADDR_sockaddr_size`, `BIO_lookup_ex`, `dgram_ctrl`, `BIO_ADDR_make`, `BIO_ADDR_rawaddress`, `BIO_ADDR_new`, `BIO_ADDR_rawport`, `BIO_ADDR_path_string`
- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.sockaddr_un` (owner: system)

Total fields: 3

- **openssl_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `BIO_lookup_ex`, `BIO_ADDR_rawaddress`, `BIO_ADDR_rawmake`, `BIO_ADDR_path_string`
- **redis_merged** [ADDR-TAKEN]
  - Fields accessed: sun_family, sun_path
  - Via functions: `anetUnixServer`, `redisContextConnectUnix`

### `struct.ssl_ctx_st` (owner: openssl_merged)

Total fields: 98

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_method_st` (owner: openssl_merged)

Total fields: 29

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.ssl_st` (owner: openssl_merged)

Total fields: 130

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)

### `struct.timeval` (owner: system)

Total fields: 2

- **openssl_merged** [NO-SEAL]
  - Fields accessed: tv_sec, tv_usec
  - Via functions: `dtls1_ctrl`, `dtls1_handle_timeout`, `dtls1_is_timer_expired`, `ossl_pool_add_nonce_data`, `gcm_ghash_4bit`, `gcm_gmult_4bit`, `BIO_socket_wait`, `dgram_read`, `def_time_cb`
- **redis_merged** [ACCESSOR]
  - Fields accessed: tv_sec
  - Via functions: `aeProcessEvents`, `_redisContextConnectTcp`, `redisContextConnectUnix`

### `struct.tm` (owner: system)

Total fields: 11

- **openssl_merged** [ACCESSOR]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday
  - Via functions: `ossl_asn1_time_print_ex`, `ossl_asn1_time_to_tm`, `OPENSSL_gmtime_adj`, `ossl_asn1_time_from_tm`, `ASN1_TIME_to_generalizedtime`, `ASN1_TIME_set_string_X509`, `OPENSSL_gmtime_diff`, `TS_RESP_create_response`
- **redis_merged** [ADDR-TAKEN]
  - Fields accessed: tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst
  - Via functions: `updateCachedTime`, `serverCron`, `initServerConfig`, `nolocks_localtime`

### `struct.x509_st` (owner: openssl_merged)

Total fields: 27

- **redis_merged** [SEAL]
  - Holds pointer opaquely (never dereferences)
