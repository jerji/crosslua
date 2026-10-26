// Minimal mbedtls config for the HOST tests: just what LuaCrypto.cpp uses (the same modules biscuit's TOTP / PIN / SD
// encryption apps call on the device). The firmware links the ESP-IDF build of the same library (hardware SHA/AES).
#define MBEDTLS_SHA1_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_MD_C
#define MBEDTLS_AES_C
#define MBEDTLS_CIPHER_MODE_CBC
#define MBEDTLS_NO_PLATFORM_ENTROPY
