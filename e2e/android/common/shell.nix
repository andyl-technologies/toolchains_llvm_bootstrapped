{ pkgs ? import <nixpkgs> {
    config = {
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  },
}:

let
  androidEnv = pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
    ndkVersions = [ "27.3.13750724" ];
  };
  ndkHome = "${androidEnv.androidsdk}/libexec/android-sdk/ndk/27.3.13750724";
in
pkgs.mkShell {
  packages = [
    pkgs.bazel_8
    pkgs.jdk21
    pkgs.file
    pkgs.binutils # readelf
    pkgs.git
  ];

  env.ANDROID_NDK_HOME = ndkHome;
  env.JAVA_HOME = pkgs.jdk21.home;
}
