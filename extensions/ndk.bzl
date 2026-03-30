"""Android NDK sysroot extension for toolchains_llvm_bootstrapped.

Provides two modes for supplying the NDK sysroot:
  - ndk.from_archive: download a known NDK version from Google by release
    name (e.g. "r27d"). Known versions and their per-OS URLs/checksums
    are maintained in ndk_versions.json.
  - ndk.host: use the NDK already installed on the host (Nixpkgs, Android Studio)

The extension creates @android_ndk_sysroot with:
  - The sysroot directory (Bionic headers, CRT objects, system libraries)
  - A resource directory with compiler-rt builtins from the NDK
  - A defs.bzl with the API level

When no NDK is configured, a stub repo is created so that select()
branches referencing @android_ndk_sysroot can resolve without error.
"""

load("@bazel_features//:features.bzl", "bazel_features")

_NDK_VERSIONS_INDEX_FILE = "//extensions:ndk_versions.json"

_DEFAULT_API_LEVEL = 28

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

def _find_ndk_builtins_dir(ndk_prebuilt_path, clang_version):
    """Locate the NDK's lib/clang/<ver>/lib/linux/ directory.

    When clang_version is known (from_archive mode), go directly to the
    expected path.  Otherwise (host mode), scan lib/clang/*/ for it.
    Returns None if the directory cannot be found.
    """
    clang_lib_dir = ndk_prebuilt_path.get_child("lib").get_child("clang")
    if not clang_lib_dir.exists:
        return None

    if clang_version:
        candidate = clang_lib_dir.get_child(str(clang_version)).get_child("lib").get_child("linux")
        if candidate.exists:
            return candidate
        fail("Expected NDK builtins at {} but directory does not exist".format(candidate))

    # Host mode: scan for the first clang version directory.
    for entry in clang_lib_dir.readdir():
        candidate = entry.get_child("lib").get_child("linux")
        if candidate.exists:
            return candidate
    return None

def _create_resource_dir(rctx, ndk_prebuilt_path, api_level, clang_version = 0):
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

    ndk_builtins_dir = _find_ndk_builtins_dir(ndk_prebuilt_path, clang_version)
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

def _ndk_sysroot_host_impl(rctx):
    ndk_home = rctx.os.environ.get("ANDROID_NDK_HOME")
    if not ndk_home:
        fail("Environment variable 'ANDROID_NDK_HOME' is not set")

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

_ndk_sysroot_host = repository_rule(
    implementation = _ndk_sysroot_host_impl,
    environ = ["ANDROID_NDK_HOME"],
    attrs = {
        "api_level": attr.int(mandatory = True),
    },
)

def _ndk_sysroot_from_archive_impl(rctx):
    host_os = _NDK_PREBUILT_TARGET.get(rctx.os.name)
    if not host_os:
        fail("Unsupported host OS '{}' for NDK archive download".format(rctx.os.name))

    # The version registry is a JSON dict keyed by OS name, each with
    # "url" and "sha256".  The extension impl serialises it for us.
    registry = json.decode(rctx.attr.version_info)
    os_entry = registry.get(rctx.os.name)
    if not os_entry:
        fail("NDK version '{}' has no archive for host OS '{}'".format(
            rctx.attr.version,
            rctx.os.name,
        ))

    strip_prefix = "{}/toolchains/llvm/prebuilt/{}".format(
        rctx.attr.archive_prefix,
        host_os,
    )

    rctx.download_and_extract(
        url = os_entry["url"],
        sha256 = os_entry["sha256"],
        stripPrefix = strip_prefix,
        output = "ndk_prebuilt",
    )

    ndk_prebuilt = rctx.path("ndk_prebuilt")
    sysroot = ndk_prebuilt.get_child("sysroot")
    if not sysroot.exists:
        fail("NDK sysroot not found at {}: expected the archive to contain a prebuilt directory with sysroot/".format(sysroot))

    rctx.symlink(sysroot, "sysroot")
    _create_resource_dir(
        rctx,
        ndk_prebuilt,
        rctx.attr.api_level,
        clang_version = rctx.attr.clang_version,
    )

    rctx.file("BUILD.bazel", _build_content(rctx.attr.api_level))
    rctx.file("defs.bzl", _defs_content(rctx.attr.api_level))

_ndk_sysroot_from_archive = repository_rule(
    implementation = _ndk_sysroot_from_archive_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "version_info": attr.string(mandatory = True),
        "archive_prefix": attr.string(mandatory = True),
        "clang_version": attr.int(mandatory = True),
        "api_level": attr.int(mandatory = True),
    },
)

def _ndk_sysroot_stub_impl(rctx):
    rctx.file("BUILD.bazel", _STUB_BUILD_CONTENT)
    rctx.file("defs.bzl", _defs_content(rctx.attr.api_level))

_ndk_sysroot_stub = repository_rule(
    implementation = _ndk_sysroot_stub_impl,
    attrs = {
        "api_level": attr.int(mandatory = True),
    },
)

# -- Module extension --

def _get_single_tag(mctx, tag_name):
    """Return the winning tag for a single-valued NDK tag class, or None.

    Resolution order: root module wins; otherwise fall back to the first
    non-root module that specifies the tag.  Fails if any single module
    supplies more than one tag of the same class.
    """
    selected = None
    for mod in mctx.modules:
        tags = getattr(mod.tags, tag_name)
        if len(tags) > 1:
            fail("Only 1 ndk.{}(...) tag is allowed per module, but '{}' has {}".format(
                tag_name,
                mod.name,
                len(tags),
            ))
        if not tags:
            continue
        if getattr(mod, "is_root", False):
            return tags[0]
        selected = tags[0]
    return selected

def _ndk_extension_impl(mctx):
    api_level_tag = _get_single_tag(mctx, "api_level")
    api_level = api_level_tag.level if api_level_tag else _DEFAULT_API_LEVEL

    from_archive = _get_single_tag(mctx, "from_archive")
    host = _get_single_tag(mctx, "host")

    if from_archive and host:
        fail("ndk: specify either from_archive or host, not both")

    if from_archive:
        ndk_versions = json.decode(mctx.read(Label(_NDK_VERSIONS_INDEX_FILE)))
        version = from_archive.version
        version_info = ndk_versions.get(version)
        if not version_info:
            fail("Unknown NDK version '{}': not found in {}. Available: {}".format(
                version,
                _NDK_VERSIONS_INDEX_FILE,
                ", ".join(sorted(ndk_versions.keys())),
            ))

        min_api = version_info.get("min_api_level", 0)
        if min_api and api_level < min_api:
            fail("NDK {} requires api_level >= {}, got {}".format(
                version,
                min_api,
                api_level,
            ))

        _ndk_sysroot_from_archive(
            name = "android_ndk_sysroot",
            version = version,
            version_info = json.encode(version_info.get("platforms", {})),
            archive_prefix = version_info.get("archive_prefix", ""),
            clang_version = version_info.get("clang_version", 0),
            api_level = api_level,
        )
    elif host:
        _ndk_sysroot_host(
            name = "android_ndk_sysroot",
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
        "version": attr.string(mandatory = True),
    },
)

_host_tag = tag_class(
    attrs = {},
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
        "host": _host_tag,
        "api_level": _api_level_tag,
    },
)
