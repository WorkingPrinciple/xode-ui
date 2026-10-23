#include <stdint.h>

typedef uint32_t DWORD;
typedef int BOOL;
typedef void *HANDLE;
typedef struct { DWORD dwLowDateTime, dwHighDateTime; } FILETIME;
#define FALSE 0
#define SYNCHRONIZE 0x00100000u
#define PROCESS_QUERY_LIMITED_INFORMATION 0x1000u
#define WAIT_OBJECT_0 0u
#define WAIT_TIMEOUT 258u
#define WAIT_FAILED 0xffffffffu
HANDLE OpenProcess(DWORD, BOOL, DWORD);
DWORD GetProcessId(HANDLE);
BOOL GetProcessTimes(HANDLE, FILETIME *, FILETIME *, FILETIME *, FILETIME *);
BOOL QueryFullProcessImageNameA(HANDLE, DWORD, char *, DWORD *);
DWORD WaitForSingleObject(HANDLE, DWORD);
BOOL GetExitCodeProcess(HANDLE, DWORD *);
BOOL CloseHandle(HANDLE);
DWORD GetLastError(void);
