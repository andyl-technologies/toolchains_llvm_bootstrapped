"""Android NDK sysroot extension for toolchains_llvm_bootstrapped.

Provides two modes for supplying the NDK sysroot:
  - ndk.from_archive: download from Google (CI, non-Nix users)
  - ndk.from_path: local path via env var (Nixpkgs, pre-installed NDK)

The extension creates @android_ndk_sysroot with:
  - The sysroot directory (Bionic headers, CRT objects, system libraries)
  - A resource directory with compiler-rt builtins from the NDK
  - A defs.bzl with the API level

When no NDK is configured, a stub repo is created so that select()
branches referencing @android_ndk_sysroot can resolve without error.
"""

load("@bazel_features//:features.bzl", "bazel_features")

# Android target triples used in the NDK sysroot directory layout.
_TRIPLES = {
    "aarch64": "aarch64-linux-android",
    "x86_64": "x86_64-linux-android",
}

# Mapping from NDK builtins arch name to clang 22+ per-target directory name.
# Clang 22 normalizes the triple by adding "unknown" vendor.
_BUILTINS_MAP = {
    "aarch64": "aarch64-unknown-linux-android",
    "x86_64": "x86_64-unknown-linux-android",
}

def _build_content(api_level):
    """Generate BUILD.bazel content for a real NDK sysroot repo."""
    content = """\
load("@llvm//:directory.bzl", "headers_directory")

package(default_visibility = ["//visibility:public"])

headers_directory(
    name = "ndk_sysroot",
    path = "sysroot",
)

headers_directory(
    name = "android_resource_dir",
    path = "resource_dir",
)
"""

    return content

_STUB_BUILD_CONTENT = """\
package(default_visibility = ["//visibility:public"])

# Stub: no NDK configured. All targets are incompatible.
_INCOMPATIBLE = ["@platforms//:incompatible"]

filegroup(
    name = "ndk_sysroot",
    srcs = [],
    target_compatible_with = _INCOMPATIBLE,
)

filegroup(
    name = "android_resource_dir",
    srcs = [],
    target_compatible_with = _INCOMPATIBLE,
)
"""

def _defs_content(api_level):
    return 'ANDROID_API_LEVEL = "{}"\n'.format(api_level)

def _create_resource_dir(rctx, ndk_prebuilt_path, api_level):
    """Create a resource directory with NDK builtins in clang 22+ layout.

    Clang 16+ uses a per-target resource dir layout:
      <resource-dir>/lib/<normalized-target>/libclang_rt.builtins.a
      <resource-dir>/lib/<normalized-target>/libunwind.a

    All current NDK releases (r27=clang18, r28=clang19, r29=clang21) use
    the old per-OS layout with arch-suffixed filenames:
      <ndk-prebuilt>/lib/clang/<ver>/lib/linux/libclang_rt.builtins-<arch>-android.a
      <ndk-prebuilt>/lib/clang/<ver>/lib/linux/<arch>/libunwind.a

    This function creates symlinks mapping the NDK's old layout into the
    per-target layout that our LLVM 21/22 clang expects.
    """
    api = str(api_level)

    # Find the NDK's clang version directory.
    clang_lib_dir = ndk_prebuilt_path.get_child("lib").get_child("clang")
    if not clang_lib_dir.exists:
        return

    ndk_builtins_dir = None
    for entry in clang_lib_dir.readdir():
        candidate = entry.get_child("lib").get_child("linux")
        if candidate.exists:
            ndk_builtins_dir = candidate
            break
    if not ndk_builtins_dir:
        return

    for arch, ndk_arch in _TRIPLES.items():
        short_arch = ndk_arch.split("-")[0]
        ndk_builtins = ndk_builtins_dir.get_child(
            "libclang_rt.builtins-{}-android.a".format(short_arch),
        )
        if not ndk_builtins.exists:
            continue

        # Clang normalizes the triple by adding "unknown" vendor.
        normalized_triple = _BUILTINS_MAP[arch] + api
        target_dir = "resource_dir/lib/{}".format(normalized_triple)
        rctx.symlink(ndk_builtins, target_dir + "/libclang_rt.builtins.a")

        # Also map libunwind.a — needed for C++ exception handling.
        # NDK stores it at lib/clang/<ver>/lib/linux/<arch>/libunwind.a
        ndk_unwind = ndk_builtins_dir.get_child(short_arch).get_child("libunwind.a")
        if ndk_unwind.exists:
            rctx.symlink(ndk_unwind, target_dir + "/libunwind.a")

# -- Repository rules --

# Google officially supports x86-64 only for Linux & Windows. On macOS the
# subdirectory is still darwin-x86_64 for historical reasons, and actually
# contains universal binaries.
_NDK_PREBUILT_TARGET = {
    "linux": "linux-x86_64",
    "mac os x": "darwin-x86_64",
    "windows": "windows-x86_64",
}

def _ndk_sysroot_from_path_impl(rctx):
    ndk_home = rctx.os.environ.get(rctx.attr.path_env)
    if not ndk_home:
        fail("Environment variable '{}' is not set".format(rctx.attr.path_env))

    ndk_home_path = rctx.path(ndk_home)

    # Auto-detect the NDK prebuilt host directory from the repository rule's
    # host OS. The NDK layout is: toolchains/llvm/prebuilt/<host>/sysroot
    host_dir = _NDK_PREBUILT_TARGET.get(rctx.os.name)
    if not host_dir:
        fail("Unsupported host OS '{}' for NDK sysroot detection".format(rctx.os.name))
    sysroot_path = rctx.path(
        str(ndk_home_path) + "/toolchains/llvm/prebuilt/{}/sysroot".format(host_dir),
    )

    if not sysroot_path.exists:
        fail("NDK sysroot not found at {}".format(sysroot_path))

    rctx.symlink(sysroot_path, "sysroot")

    # The NDK prebuilt toolchain root is the parent of the sysroot.
    ndk_prebuilt = rctx.path(str(sysroot_path.dirname))
    _create_resource_dir(rctx, ndk_prebuilt, rctx.attr.api_level)

    rctx.file("BUILD.bazel", _build_content(rctx.attr.api_level))
    rctx.file("defs.bzl", _defs_content(rctx.attr.api_level))

_ndk_sysroot_from_path = repository_rule(
    implementation = _ndk_sysroot_from_path_impl,
    environ = ["ANDROID_NDK_HOME"],
    attrs = {
        "path_env": attr.string(default = "ANDROID_NDK_HOME"),
        "api_level": attr.int(default = 28),
    },
)

def _ndk_sysroot_from_archive_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
        stripPrefix = rctx.attr.strip_prefix,
        output = "sysroot",
    )

    # For archive mode, builtins may be included if the archive contains
    # the full NDK prebuilt tree. Try to find them.
    prebuilt_guess = rctx.path("sysroot").dirname
    _create_resource_dir(rctx, prebuilt_guess, rctx.attr.api_level)

    rctx.file("BUILD.bazel", _build_content(rctx.attr.api_level))
    rctx.file("defs.bzl", _defs_content(rctx.attr.api_level))

_ndk_sysroot_from_archive = repository_rule(
    implementation = _ndk_sysroot_from_archive_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(default = ""),
        "api_level": attr.int(default = 28),
    },
)

def _ndk_sysroot_stub_impl(rctx):
    rctx.file("BUILD.bazel", _STUB_BUILD_CONTENT)
    rctx.file("defs.bzl", _defs_content(rctx.attr.api_level))

_ndk_sysroot_stub = repository_rule(
    implementation = _ndk_sysroot_stub_impl,
    attrs = {
        "api_level": attr.int(default = 28),
    },
)

# -- Module extension --

def _ndk_extension_impl(mctx):
    api_level = 28

    for mod in mctx.modules:
        for tag in mod.tags.api_level:
            api_level = tag.level

    from_archive = None
    from_path = None

    for mod in mctx.modules:
        for tag in mod.tags.from_archive:
            from_archive = tag
        for tag in mod.tags.from_path:
            from_path = tag

    if from_archive and from_path:
        fail("ndk: specify either from_archive or from_path, not both")

    if from_archive:
        _ndk_sysroot_from_archive(
            name = "android_ndk_sysroot",
            urls = from_archive.urls,
            sha256 = from_archive.sha256,
            strip_prefix = from_archive.strip_prefix,
            api_level = api_level,
        )
    elif from_path:
        _ndk_sysroot_from_path(
            name = "android_ndk_sysroot",
            path_env = from_path.path_env,
            api_level = api_level,
        )
    else:
        # No NDK configured -- create a stub repo so select() branches
        # referencing @android_ndk_sysroot can resolve without error.
        _ndk_sysroot_stub(
            name = "android_ndk_sysroot",
            api_level = api_level,
        )

    metadata_kwargs = {}
    if bazel_features.external_deps.extension_metadata_has_reproducible:
        metadata_kwargs["reproducible"] = True

    return mctx.extension_metadata(**metadata_kwargs)

_from_archive_tag = tag_class(
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(default = ""),
    },
)

_from_path_tag = tag_class(
    attrs = {
        "path_env": attr.string(default = "ANDROID_NDK_HOME"),
    },
)

_api_level_tag = tag_class(
    attrs = {
        "level": attr.int(mandatory = True),
    },
)

ndk = module_extension(
    implementation = _ndk_extension_impl,
    tag_classes = {
        "from_archive": _from_archive_tag,
        "from_path": _from_path_tag,
        "api_level": _api_level_tag,
    },
)
