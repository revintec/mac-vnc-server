/* SwiftPM configuration for the vendored, native-API zlib-ng 2.3.3 sources.
 * Force-included because some upstream architecture files test feature macros
 * before their first include. No upstream source file is modified.
 */
#ifndef CVNC_ZLIB_CONFIG_H
#define CVNC_ZLIB_CONFIG_H
#define HAVE_VISIBILITY_HIDDEN
#define HAVE_ATTRIBUTE_ALIGNED
#define HAVE_BUILTIN_ASSUME_ALIGNED
#define HAVE_BUILTIN_CTZ
#define HAVE_BUILTIN_CTZLL
#define HAVE_UNISTD_H
#define WITH_ALL_FALLBACKS
#define WITH_OPTIM
#if defined(__aarch64__)
#define ARM_FEATURES
#define ARM_NEON
#define ARM_NEON_HASLD4
#if defined(__ARM_FEATURE_CRC32)
#define ARM_CRC32
#define ARM_CRC32_INTRIN
#define HAVE_ARM_ACLE_H
#endif
#endif
#endif
