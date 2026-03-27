#include "src/cpp_helper.h"

#include <stdexcept>
#include <string>

extern "C" int concatenated_length(const char *a, const char *b) {
    if (a == nullptr || b == nullptr) {
        throw std::invalid_argument("null pointer passed to concatenated_length");
    }
    std::string result = std::string(a) + std::string(b);
    return static_cast<int>(result.size());
}
