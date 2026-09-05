#ifndef SMC_BRIDGE_H
#define SMC_BRIDGE_H

#include <stdint.h>

// Layout de memoria dos structs do AppleSMC. Precisa bater byte-a-byte com o
// que o kernel espera, por isso definimos em C (e nao em Swift) para herdar o
// alinhamento/padding do compilador C.

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;   // FourCharCode do tipo, ex: 'flt ', 'ui8 '
    uint8_t  dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t                key;    // FourCharCode da chave, ex: 'F0Ac'
    SMCKeyData_vers_t       vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t    keyInfo;
    uint8_t                 result;
    uint8_t                 status;
    uint8_t                 data8;   // comando (READ_BYTES, WRITE_BYTES, ...)
    uint32_t                data32;
    uint8_t                 bytes[32];
} SMCKeyData_t;

// Selector do user client (IOConnectCallStructMethod)
enum { kSMCHandleYPCEvent = 2 };

// Comandos SMC (vao em data8)
enum {
    kSMCCmdReadBytes    = 5,
    kSMCCmdWriteBytes   = 6,
    kSMCCmdReadIndex    = 8,
    kSMCCmdReadKeyInfo  = 9,
};

#endif /* SMC_BRIDGE_H */
