/*
 * Minimal NVML stub header for ztop-g.
 *
 * Covers only the NVML API surface we use. Function signatures match
 * libnvidia-ml.so exactly — this is not a mock, it's a minimal declaration
 * set that links against the real library on the machine.
 *
 * Source: https://docs.nvidia.com/deploy/nvml-api/
 * NVML v6+ (CUDA 5.0+) — all functions here available on 595.x driver.
 */

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Return codes ──────────────────────────────────────────────────────────────

typedef enum nvmlReturn_enum {
    NVML_SUCCESS                   = 0,
    NVML_ERROR_UNINITIALIZED       = 1,
    NVML_ERROR_INVALID_ARGUMENT    = 2,
    NVML_ERROR_NOT_SUPPORTED       = 3,
    NVML_ERROR_NO_PERMISSION       = 4,
    NVML_ERROR_ALREADY_INITIALIZED = 5,
    NVML_ERROR_NOT_FOUND           = 6,
    NVML_ERROR_INSUFFICIENT_SIZE   = 7,
    NVML_ERROR_DRIVER_NOT_LOADED   = 9,
    NVML_ERROR_TIMEOUT             = 10,
    NVML_ERROR_UNKNOWN             = 999,
} nvmlReturn_t;

// ── Opaque handle ─────────────────────────────────────────────────────────────

typedef struct { void *handle; } *nvmlDevice_t;

// ── Enums ─────────────────────────────────────────────────────────────────────

typedef enum nvmlTemperatureSensors_enum {
    NVML_TEMPERATURE_GPU = 0,
} nvmlTemperatureSensors_t;

typedef enum nvmlClockType_enum {
    NVML_CLOCK_GRAPHICS = 0,
    NVML_CLOCK_SM       = 1,
    NVML_CLOCK_MEM      = 2,
    NVML_CLOCK_VIDEO    = 3,
} nvmlClockType_t;

typedef enum nvmlPcieUtilCounter_enum {
    NVML_PCIE_UTIL_TX_BYTES = 0,
    NVML_PCIE_UTIL_RX_BYTES = 1,
} nvmlPcieUtilCounter_t;

// ── Structs ───────────────────────────────────────────────────────────────────

typedef struct nvmlUtilization_st {
    unsigned int gpu;    // GPU core utilization %
    unsigned int memory; // Memory controller utilization %
} nvmlUtilization_t;

typedef struct nvmlMemory_st {
    unsigned long long total; // bytes
    unsigned long long free;  // bytes
    unsigned long long used;  // bytes
} nvmlMemory_t;

typedef struct nvmlProcessInfo_v1_st {
    unsigned int       pid;
    unsigned long long usedGpuMemory; // bytes; NVML_VALUE_NOT_AVAILABLE if unknown
    unsigned int       gpuInstanceId;
    unsigned int       computeInstanceId;
} nvmlProcessInfo_v1_t;
typedef nvmlProcessInfo_v1_t nvmlProcessInfo_t;

#define NVML_VALUE_NOT_AVAILABLE ((unsigned long long)18446744073709551615ULL)
#define NVML_DEVICE_NAME_BUFFER_SIZE 64

// ── Init/shutdown ─────────────────────────────────────────────────────────────

nvmlReturn_t nvmlInit(void);
nvmlReturn_t nvmlInit_v2(void);
nvmlReturn_t nvmlShutdown(void);
const char*  nvmlErrorString(nvmlReturn_t result);

// ── Device enumeration ────────────────────────────────────────────────────────

nvmlReturn_t nvmlDeviceGetCount(unsigned int *deviceCount);
nvmlReturn_t nvmlDeviceGetCount_v2(unsigned int *deviceCount);
nvmlReturn_t nvmlDeviceGetHandleByIndex(unsigned int index, nvmlDevice_t *device);
nvmlReturn_t nvmlDeviceGetHandleByIndex_v2(unsigned int index, nvmlDevice_t *device);
nvmlReturn_t nvmlDeviceGetName(nvmlDevice_t device, char *name, unsigned int length);

// ── Utilization + memory ──────────────────────────────────────────────────────

nvmlReturn_t nvmlDeviceGetUtilizationRates(nvmlDevice_t device, nvmlUtilization_t *utilization);
nvmlReturn_t nvmlDeviceGetMemoryInfo(nvmlDevice_t device, nvmlMemory_t *memory);

// ── Thermal + power ───────────────────────────────────────────────────────────

nvmlReturn_t nvmlDeviceGetTemperature(nvmlDevice_t device,
    nvmlTemperatureSensors_t sensorType, unsigned int *temp);
nvmlReturn_t nvmlDeviceGetPowerUsage(nvmlDevice_t device, unsigned int *power);  // milliwatts
nvmlReturn_t nvmlDeviceGetEnforcedPowerLimit(nvmlDevice_t device, unsigned int *limit); // mW

// ── Clocks ────────────────────────────────────────────────────────────────────

nvmlReturn_t nvmlDeviceGetClockInfo(nvmlDevice_t device,
    nvmlClockType_t type, unsigned int *clock); // MHz

// ── PCIe throughput ───────────────────────────────────────────────────────────

nvmlReturn_t nvmlDeviceGetPcieThroughput(nvmlDevice_t device,
    nvmlPcieUtilCounter_t counter, unsigned int *value); // KB/s

// ── Per-process VRAM ─────────────────────────────────────────────────────────

nvmlReturn_t nvmlDeviceGetComputeRunningProcesses(nvmlDevice_t device,
    unsigned int *infoCount, nvmlProcessInfo_t *infos);
nvmlReturn_t nvmlDeviceGetGraphicsRunningProcesses(nvmlDevice_t device,
    unsigned int *infoCount, nvmlProcessInfo_t *infos);

#ifdef __cplusplus
}
#endif
