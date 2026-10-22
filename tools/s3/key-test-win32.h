#include <stdint.h>

typedef unsigned long DWORD;
typedef unsigned short WORD;
typedef unsigned int UINT;
typedef int BOOL;
typedef intptr_t LPARAM;
typedef void *HWND;
typedef struct {
    DWORD type;
    struct { WORD wScan; DWORD dwFlags; } ki;
} INPUT;
#define CALLBACK
#define TRUE 1
#define INPUT_KEYBOARD 1
#define MAPVK_VK_TO_VSC_EX 4
#define KEYEVENTF_SCANCODE 8
#define KEYEVENTF_EXTENDEDKEY 1
#define KEYEVENTF_KEYUP 2
BOOL IsWindow(HWND);
BOOL IsWindowVisible(HWND);
int GetWindowTextLengthA(HWND);
DWORD GetWindowThreadProcessId(HWND, DWORD *);
int GetWindowTextA(HWND, char *, int);
int GetClassNameA(HWND, char *, int);
BOOL EnumWindows(BOOL (*)(HWND, LPARAM), LPARAM);
HWND GetForegroundWindow(void);
BOOL SetForegroundWindow(HWND);
void Sleep(DWORD);
UINT MapVirtualKeyA(UINT, UINT);
UINT SendInput(UINT, INPUT *, int);
DWORD GetLastError(void);
unsigned long long GetTickCount64(void);
