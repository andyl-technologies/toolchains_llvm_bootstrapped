#ifndef CPP_HELPER_H
#define CPP_HELPER_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns the length of the concatenation of two strings.
// Forces C++ standard library usage (std::string, operator new, etc.).
int concatenated_length(const char *a, const char *b);

#ifdef __cplusplus
}
#endif

#endif /* CPP_HELPER_H */
