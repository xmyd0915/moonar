#include "moonbit.h"
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#else
#include <sys/resource.h>
#endif

// Process lifetime high-water mark, including fixture setup and warmup.
// Return bytes on every host; this is not an allocation counter or heap delta.
MOONBIT_FFI_EXPORT double moonar_benchmark_peak_rss(void) {
#ifdef _WIN32
  typedef BOOL (WINAPI *memory_info_fn)(HANDLE, PPROCESS_MEMORY_COUNTERS, DWORD);
  HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
  memory_info_fn info = kernel ? (memory_info_fn)GetProcAddress(kernel, "K32GetProcessMemoryInfo") : NULL;
  PROCESS_MEMORY_COUNTERS counters;
  if (!info || !info(GetCurrentProcess(), &counters, sizeof(counters))) return -1.0;
  return (double)counters.PeakWorkingSetSize;
#else
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1.0;
#ifdef __APPLE__
  return (double)usage.ru_maxrss;
#else
  return (double)usage.ru_maxrss * 1024.0;
#endif
#endif
}

// A separate short-lived probe confirms byte units by touching 64 MiB. It never
// runs in a timed workload's process and cannot inflate that sample's peak.
MOONBIT_FFI_EXPORT double moonar_benchmark_memory_probe(void) {
  const size_t size = 64 * 1024 * 1024;
  volatile unsigned char *pages = (volatile unsigned char *)malloc(size);
  if (!pages) return -1.0;
  for (size_t i = 0; i < size; i += 4096) pages[i] = 1;
  double peak = moonar_benchmark_peak_rss();
  free((void *)pages);
  return peak;
}
