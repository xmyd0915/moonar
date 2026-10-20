#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif

#include "moonbit.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#endif

static moonbit_bytes_t moonar_message(const char *message) {
  size_t length = strlen(message);
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)length, 0);
  memcpy(result, message, length);
  return result;
}

static moonbit_bytes_t moonar_os_error(const char *operation, unsigned long code) {
  char message[512];
#ifdef _WIN32
  snprintf(message, sizeof(message), "%s (Windows error %lu)", operation, code);
#else
  snprintf(message, sizeof(message), "%s: %s", operation, strerror((int)code));
#endif
  return moonar_message(message);
}

static moonbit_bytes_t moonar_path_result(const char *path) {
  size_t length = strlen(path);
  moonbit_bytes_t result = moonbit_make_bytes((int32_t)length + 1, 0);
  memcpy(result + 1, path, length);
  return result;
}

#ifdef _WIN32
static wchar_t *moonar_wide(const char *path) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (!count) return NULL;
  wchar_t *wide = (wchar_t *)malloc((size_t)count * sizeof(wchar_t));
  if (!wide) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count)) {
    free(wide);
    return NULL;
  }
  return wide;
}

static wchar_t *moonar_final_path(const wchar_t *path, int directory) {
  HANDLE handle = CreateFileW(
      path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      NULL, OPEN_EXISTING, directory ? FILE_FLAG_BACKUP_SEMANTICS : 0, NULL);
  if (handle == INVALID_HANDLE_VALUE) return NULL;
  DWORD count = GetFinalPathNameByHandleW(handle, NULL, 0, FILE_NAME_NORMALIZED);
  if (!count) {
    DWORD code = GetLastError();
    CloseHandle(handle);
    SetLastError(code);
    return NULL;
  }
  wchar_t *result = (wchar_t *)malloc(((size_t)count + 1) * sizeof(wchar_t));
  if (!result) {
    CloseHandle(handle);
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  DWORD actual = GetFinalPathNameByHandleW(handle, result, count + 1, FILE_NAME_NORMALIZED);
  DWORD code = GetLastError();
  CloseHandle(handle);
  if (!actual || actual > count) {
    free(result);
    SetLastError(actual > count ? ERROR_INSUFFICIENT_BUFFER : code);
    return NULL;
  }
  return result;
}
#endif

MOONBIT_FFI_EXPORT moonbit_bytes_t moonar_atomic_write(
    moonbit_bytes_t path_bytes, moonbit_bytes_t data, int32_t size, int32_t overwrite) {
  const char *path = (const char *)path_bytes;
#ifdef _WIN32
  wchar_t *destination = moonar_wide(path);
  if (!destination) return moonar_os_error("invalid destination path", GetLastError());
  size_t length = wcslen(destination);
  wchar_t *temporary = (wchar_t *)malloc((length + 96) * sizeof(wchar_t));
  if (!temporary) {
    free(destination);
    return moonar_message("out of memory while creating output file");
  }
  static volatile LONG sequence = 0;
  HANDLE file = INVALID_HANDLE_VALUE;
  DWORD code = ERROR_FILE_EXISTS;
  for (unsigned attempt = 0; attempt < 128; ++attempt) {
    unsigned long next = (unsigned long)InterlockedIncrement(&sequence);
    swprintf(temporary, length + 96, L"%ls.moonar-%lu-%lu-%lu.tmp",
             destination, (unsigned long)GetCurrentProcessId(),
             (unsigned long)GetTickCount(), next);
    file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) break;
    code = GetLastError();
    if (code != ERROR_FILE_EXISTS && code != ERROR_ALREADY_EXISTS) break;
  }
  if (file == INVALID_HANDLE_VALUE) {
    free(temporary);
    free(destination);
    return moonar_os_error("cannot create temporary output", code);
  }
  size_t cursor = 0;
  const char *operation = "cannot write temporary output";
  while (cursor < (size_t)size) {
    DWORD written = 0;
    if (!WriteFile(file, data + cursor, (DWORD)((size_t)size - cursor), &written, NULL) || !written) {
      code = GetLastError();
      if (!code) code = ERROR_WRITE_FAULT;
      goto windows_failure;
    }
    cursor += written;
  }
  operation = "cannot flush temporary output";
  if (!FlushFileBuffers(file)) {
    code = GetLastError();
    goto windows_failure;
  }
  operation = "cannot close temporary output";
  if (!CloseHandle(file)) {
    code = GetLastError();
    file = INVALID_HANDLE_VALUE;
    goto windows_failure;
  }
  file = INVALID_HANDLE_VALUE;
  operation = "cannot publish output";
  if (!MoveFileExW(temporary, destination,
                  MOVEFILE_WRITE_THROUGH | (overwrite ? MOVEFILE_REPLACE_EXISTING : 0))) {
    code = GetLastError();
    goto windows_failure;
  }
  free(temporary);
  free(destination);
  return moonar_message("");

windows_failure:
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  DeleteFileW(temporary);
  free(temporary);
  free(destination);
  return moonar_os_error(operation, code);
#else
  size_t length = strlen(path);
  char *temporary = (char *)malloc(length + 32);
  if (!temporary) return moonar_message("out of memory while creating output file");
  snprintf(temporary, length + 32, "%s.moonar-XXXXXX", path);
  int file = mkstemp(temporary);
  if (file < 0) {
    int code = errno;
    free(temporary);
    return moonar_os_error("cannot create temporary output", (unsigned long)code);
  }
  // Preserve an existing archive's access mode. Newly created archives retain
  // mkstemp's private mode until the user chooses broader permissions.
  struct stat original;
  if (overwrite && stat(path, &original) == 0 && S_ISREG(original.st_mode)) {
    if (fchmod(file, original.st_mode & 0777) != 0) {
      int code = errno;
      close(file);
      unlink(temporary);
      free(temporary);
      return moonar_os_error("cannot preserve output permissions", (unsigned long)code);
    }
  }
  const char *operation = "cannot write temporary output";
  int code = 0;
  size_t cursor = 0;
  while (cursor < (size_t)size) {
    ssize_t written = write(file, data + cursor, (size_t)size - cursor);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) {
      code = written < 0 ? errno : EIO;
      goto posix_failure;
    }
    cursor += (size_t)written;
  }
  operation = "cannot flush temporary output";
  if (fsync(file) != 0) {
    code = errno;
    goto posix_failure;
  }
  operation = "cannot close temporary output";
  if (close(file) != 0) {
    code = errno;
    file = -1;
    goto posix_failure;
  }
  file = -1;
  operation = "cannot publish output";
  if (overwrite) {
    if (rename(temporary, path) != 0) {
      code = errno;
      goto posix_failure;
    }
  } else {
    // link is an atomic, no-replace publication in the same directory.
    if (link(temporary, path) != 0) {
      code = errno;
      goto posix_failure;
    }
    unlink(temporary);
  }
  free(temporary);
  return moonar_message("");

posix_failure:
  if (file >= 0) close(file);
  unlink(temporary);
  free(temporary);
  return moonar_os_error(operation, (unsigned long)code);
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonar_check_member_path(
    moonbit_bytes_t base_bytes, moonbit_bytes_t target_bytes) {
  const char *base = (const char *)base_bytes;
  const char *target = (const char *)target_bytes;
#ifdef _WIN32
  wchar_t *wide_base = moonar_wide(base);
  if (!wide_base) return moonar_os_error("invalid archive directory", GetLastError());
  wchar_t *wide_target = moonar_wide(target);
  if (!wide_target) {
    DWORD code = GetLastError();
    free(wide_base);
    return moonar_os_error("invalid external member path", code);
  }
  wchar_t *resolved_base = moonar_final_path(wide_base, 1);
  DWORD base_code = GetLastError();
  wchar_t *resolved_target = moonar_final_path(wide_target, 0);
  DWORD target_code = GetLastError();
  free(wide_base);
  free(wide_target);
  if (!resolved_base || !resolved_target) {
    int missing_base = resolved_base == NULL;
    free(resolved_base);
    free(resolved_target);
    return moonar_os_error(missing_base ? "cannot resolve archive directory" : "cannot resolve external member",
                           missing_base ? base_code : target_code);
  }
  size_t base_length = wcslen(resolved_base);
  size_t target_length = wcslen(resolved_target);
  while (base_length > 0 && (resolved_base[base_length - 1] == L'\\' || resolved_base[base_length - 1] == L'/'))
    --base_length;
  int inside = target_length > base_length &&
      CompareStringOrdinal(resolved_base, (int)base_length, resolved_target, (int)base_length, FALSE) == CSTR_EQUAL &&
      (resolved_target[base_length] == L'\\' || resolved_target[base_length] == L'/');
  free(resolved_base);
  free(resolved_target);
  return moonar_message(inside ? "" : "external member resolves outside the archive directory");
#else
  char *resolved_base = realpath(base, NULL);
  if (!resolved_base) return moonar_os_error("cannot resolve archive directory", (unsigned long)errno);
  char *resolved_target = realpath(target, NULL);
  if (!resolved_target) {
    int code = errno;
    free(resolved_base);
    return moonar_os_error("cannot resolve external member", (unsigned long)code);
  }
  size_t base_length = strlen(resolved_base);
  while (base_length > 1 && resolved_base[base_length - 1] == '/') --base_length;
  int inside = strncmp(resolved_base, resolved_target, base_length) == 0 &&
      ((base_length == 1 && resolved_base[0] == '/' && resolved_target[1] != '\0') ||
       resolved_target[base_length] == '/');
  free(resolved_base);
  free(resolved_target);
  return moonar_message(inside ? "" : "external member resolves outside the archive directory");
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonar_canonical_path(moonbit_bytes_t path_bytes) {
  const char *path = (const char *)path_bytes;
#ifdef _WIN32
  wchar_t *wide = moonar_wide(path);
  if (!wide) return moonar_os_error("invalid path", GetLastError());
  wchar_t *resolved = moonar_final_path(wide, 1);
  DWORD code = GetLastError();
  free(wide);
  if (!resolved) return moonar_os_error("cannot resolve path", code);
  const wchar_t *normal = resolved;
  wchar_t *unc = NULL;
  if (wcsncmp(resolved, L"\\\\?\\UNC\\", 8) == 0) {
    size_t length = wcslen(resolved + 8);
    unc = (wchar_t *)malloc((length + 3) * sizeof(wchar_t));
    if (!unc) {
      free(resolved);
      return moonar_message("out of memory while resolving path");
    }
    unc[0] = L'\\';
    unc[1] = L'\\';
    memcpy(unc + 2, resolved + 8, (length + 1) * sizeof(wchar_t));
    normal = unc;
  } else if (wcsncmp(resolved, L"\\\\?\\", 4) == 0) {
    normal = resolved + 4;
  }
  int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, normal, -1, NULL, 0, NULL, NULL);
  if (!count) {
    code = GetLastError();
    free(unc);
    free(resolved);
    return moonar_os_error("cannot encode resolved path", code);
  }
  char *utf8 = (char *)malloc((size_t)count);
  if (!utf8) {
    free(unc);
    free(resolved);
    return moonar_message("out of memory while resolving path");
  }
  if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, normal, -1, utf8, count, NULL, NULL)) {
    code = GetLastError();
    free(utf8);
    free(unc);
    free(resolved);
    return moonar_os_error("cannot encode resolved path", code);
  }
  moonbit_bytes_t result = moonar_path_result(utf8);
  free(utf8);
  free(unc);
  free(resolved);
  return result;
#else
  char *resolved = realpath(path, NULL);
  if (!resolved) return moonar_os_error("cannot resolve path", (unsigned long)errno);
  moonbit_bytes_t result = moonar_path_result(resolved);
  free(resolved);
  return result;
#endif
}
