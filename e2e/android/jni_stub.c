// Minimal shared library exercising C library linking + function export.
// Models the pattern used by envoy_jni.so (shared lib loaded by Java via JNI).
#include "add.h"

__attribute__((visibility("default")))
int jni_add(int a, int b) {
    return add(a, b);
}
